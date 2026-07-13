const std = @import("std");
const zimple = @import("zimple");

const Vec = zimple.Vector(i32);
const Io = std.Io;
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout_file_writer.interface;

    var buf: [2048]u8 = undefined;

    try writeStr(w, &buf, "=== Zimple Benchmarks ===\n");
    try writeFmt(w, &buf, "Target: Zig 0.16.0, {s} build\n\n", .{@tagName(builtin.mode)});

    try benchStructureSizes(w, &buf);
    try benchArenaVsDirect(io, w, &buf);
    try benchTeardownScaling(io, w, &buf);

    try w.flush();
}

fn writeStr(w: *Io.Writer, buf: *[2048]u8, s: []const u8) !void {
    _ = buf;
    _ = try w.writeVec(&.{s});
}

fn writeFmt(w: *Io.Writer, buf: *[2048]u8, comptime fmt: []const u8, args: anytype) !void {
    const slice = try std.fmt.bufPrint(buf, fmt, args);
    _ = try w.writeVec(&.{slice});
}

fn benchStructureSizes(w: *Io.Writer, buf: *[2048]u8) !void {
    try writeStr(w, buf, "── Structure Sizes ──\n");
    try writeFmt(w, buf, "  Closure(struct{{i32}}, i32, i32):  {d:>4} B  (env=4 + fn ptr=8 + padding)\n", .{@sizeOf(zimple.closure.Closure(struct { x: i32 }, i32, i32))});
    try writeFmt(w, buf, "  Closure2(struct{{i32}}, i32, i32): {d:>4} B\n", .{@sizeOf(zimple.closure.Closure2(struct { x: i32 }, i32, i32, i32))});
    try writeFmt(w, buf, "  List(i32).Node:                     {d:>4} B  (tag=1 + head=4 + tail=8 + padding)\n", .{@sizeOf(zimple.List(i32).Node)});
    try writeFmt(w, buf, "  Vector(i32).Node:                   {d:>4} B  ([32]T=128 + [32]?*Node=256 + overhead)\n", .{@sizeOf(zimple.Vector(i32).Node)});
    try writeStr(w, buf, "\n");
}

fn benchArenaVsDirect(io: Io, w: *Io.Writer, buf: *[2048]u8) !void {
    const N: usize = 500_000;
    try writeFmt(w, buf, "── Bench 1: Build + Teardown ({d} push_backs) ──\n", .{N});

    const leaves: usize = (N + 31) / 32;
    const l1: usize = (leaves + 31) / 32;
    const l2: usize = (l1 + 31) / 32;
    const total_nodes = leaves + l1 + l2 + 1;
    const mem_mb = @as(f64, @floatFromInt(total_nodes * @sizeOf(Vec.Node))) / (1024.0 * 1024.0);

    try writeFmt(w, buf, "  Leaf capacity: 32, branching factor: 32\n", .{});
    try writeFmt(w, buf, "  Nodes: {d} leaves + {d} L1 + {d} L2 + 1 root = {d} total\n", .{ leaves, l1, l2, total_nodes });
    try writeFmt(w, buf, "  Memory: ~{d:.1} MB\n\n", .{mem_mb});

    // ── Arena: bulk mmap, O(pages) teardown ──
    try writeStr(w, buf, "  Arena (std.heap.ArenaAllocator wrapping page_allocator):\n");
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var vec = Vec.empty(arena.allocator());

        const b_start = try clockNanos(io);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            vec = try vec.pushBack(@intCast(i));
        }
        const build_ns = (try clockNanos(io)) - b_start;

        const t_start = try clockNanos(io);
        arena.deinit();
        const td_ns = (try clockNanos(io)) - t_start;

        const total = @as(f64, @floatFromInt(build_ns + td_ns)) / 1_000_000.0;
        try writeFmt(w, buf, "    build:    {d:>7.1} ms  (allocations: pages from OS, bump within)\n", .{nsToMs(build_ns)});
        try writeFmt(w, buf, "    teardown: {d:>7.1} µs  (free ~{d} pages)\n", .{ nsToUs(td_ns), total_nodes / 58 });
        try writeFmt(w, buf, "    total:    {d:>7.1} ms\n\n", .{total});
    }

    // ── Direct page_allocator: per-node mmap/munmap ──
    try writeStr(w, buf, "  Direct (std.heap.page_allocator per-node):\n");
    {
        var vec = Vec.empty(std.heap.page_allocator);

        const b_start = try clockNanos(io);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            vec = try vec.pushBack(@intCast(i));
        }
        const build_ns = (try clockNanos(io)) - b_start;

        const t_start = try clockNanos(io);
        vec.deinit();
        const td_ns = (try clockNanos(io)) - t_start;

        const total = @as(f64, @floatFromInt(build_ns + td_ns)) / 1_000_000.0;
        try writeFmt(w, buf, "    build:    {d:>7.1} ms  (allocations: {d} × mmap)\n", .{ nsToMs(build_ns), total_nodes });
        try writeFmt(w, buf, "    teardown: {d:>7.2} ms  (free: {d} × munmap)\n", .{ nsToMs(td_ns), total_nodes });
        try writeFmt(w, buf, "    total:    {d:>7.1} ms\n\n", .{total});
    }

    try writeStr(w, buf, "  Arena wins by avoiding per-node syscalls. Each page_allocator.create()\n");
    try writeStr(w, buf, "  is a mmap/munmap pair. Arena does bulk page allocation and bump-pointer\n");
    try writeStr(w, buf, "  sub-allocation, then tears down all pages in one loop.\n\n");
}

fn benchTeardownScaling(io: Io, w: *Io.Writer, buf: *[2048]u8) !void {
    try writeStr(w, buf, "── Bench 2: Teardown Cost by Size ──\n");
    try writeStr(w, buf, "  N          Nodes    Arena(µs)  Direct(ms)  Speedup\n");
    try writeStr(w, buf, "  ────────   ──────   ────────    ──────────  ───────\n");

    const sizes = [_]usize{ 1000, 10000, 100000, 500000 };

    for (sizes) |N| {
        const leaves = (N + 31) / 32;
        const l1 = (leaves + 31) / 32;
        const nodes = leaves + l1 + (l1 + 31) / 32 + 1;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var arena_vec = Vec.empty(arena.allocator());
        var i: usize = 0;
        while (i < N) : (i += 1) {
            arena_vec = try arena_vec.pushBack(@intCast(i));
        }
        const at_start = try clockNanos(io);
        arena.deinit();
        const arena_td = @as(f64, @floatFromInt((try clockNanos(io)) - at_start)) / 1000.0; // µs

        var direct_vec = Vec.empty(std.heap.page_allocator);
        i = 0;
        while (i < N) : (i += 1) {
            direct_vec = try direct_vec.pushBack(@intCast(i));
        }
        const dt_start = try clockNanos(io);
        direct_vec.deinit();
        const direct_td = @as(f64, @floatFromInt((try clockNanos(io)) - dt_start)) / 1_000_000.0; // ms

        const speedup = direct_td / @max(arena_td / 1000.0, 0.000001);
        try writeFmt(w, buf, "  {d:<9}  {d:<6}  {d:>7.1}      {d:>8.2}   {d:>6.0}×\n", .{ N, nodes, arena_td, direct_td, speedup });
    }

    try writeStr(w, buf, "\n");
    try writeStr(w, buf, "Summary:\n");
    try writeStr(w, buf, "  Arena teardown:     O(pages) ~ O(sqrt(n)) — frees backing pages.\n");
    try writeStr(w, buf, "  Per-node teardown:  O(nodes) — each node individually freed.\n");
    try writeStr(w, buf, "  For persistent functional structures, intermediate versions\n");
    try writeStr(w, buf, "  accumulate rapidly. Arena reclaims all of them in one pass.\n");
    try writeStr(w, buf, "  Per-node free must trace every intermediate tree separately.\n");
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn clockNanos(io: Io) !u64 {
    const ts = Io.Clock.awake.now(io);
    return @as(u64, @truncate(@as(u96, @bitCast(ts.nanoseconds))));
}
