// Performance: Zig vs Zimple wall-clock time (µs)
const std = @import("std");
const zimple = @import("zimple");
const zig_ve = @import("versioned_zig.zig");
const zim_ve = @import("versioned_zimple.zig");
const zig_mv = @import("multiview_zig.zig");
const zim_mv = @import("multiview_zimple.zig");

const WARMUP = 5;
const RUNS = 30;

fn timeOne(comptime f: anytype) !struct { min: f64, avg: f64 } {
    var times: [RUNS]f64 = undefined;
    var wi: usize = 0;
    while (wi < WARMUP) : (wi += 1) { f() catch {}; }
    for (&times) |*t| {
        const start = std.Io.Clock.now(.awake, io_g).nanoseconds;
        f() catch @panic("fail");
        t.* = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io_g).nanoseconds - start)) / 1000.0;
    }
    std.mem.sort(f64, &times, {}, struct { fn lt(_: void, a: f64, b: f64) bool { return a < b; } }.lt);
    var sum: f64 = 0; for (times) |v| sum += v;
    return .{ .min = times[0], .avg = sum / RUNS };
}

var io_g: std.Io = undefined;
var g_records: []const zig_mv.Record = &.{};
const alloc_g = std.heap.page_allocator;

fn setup() !void {
    var list = try std.ArrayList(zig_mv.Record).initCapacity(alloc_g, 50000);
    var i: i32 = 0;
    while (i < 50000) : (i += 1) {
        const cat: u8 = @truncate(@as(u32, @bitCast(i * 7)) % 5);
        try list.append(alloc_g, .{ .id = i, .category = cat, .value = @floatFromInt(@as(i32, @intCast(@mod(@as(i64, i), 2000))) - 1000) });
    }
    g_records = try list.toOwnedSlice(alloc_g);
}
fn runMvZ() !void { _ = try zig_mv.analyze(alloc_g, @ptrCast(g_records)); }
fn runMvM() !void { _ = try zim_mv.analyze(alloc_g, @ptrCast(g_records)); }

pub fn main(init: std.process.Init) !void {
    io_g = init.io;
    try setup();
    defer alloc_g.free(g_records);

    std.debug.print("\n=== Performance ({d} warmup, {d} runs, ReleaseFast) ===\n\n", .{ WARMUP, RUNS });
    std.debug.print("  {s:<15} {s:>10} {s:>10} {s:>7}\n", .{ "benchmark", "min(us)", "avg(us)", "ratio" });
    std.debug.print("  {s:-<15} {s:-<10} {s:-<10} {s:-<7}\n", .{ "", "", "", "" });


    // Versioned pipeline
    {
        const z = try timeOne(struct { fn f() !void { try zig_ve.run(alloc_g, 50000); } }.f);
        const m = try timeOne(struct { fn f() !void { try zim_ve.run(alloc_g, 50000); } }.f);
        std.debug.print("  zig-ve          {d:>10.1} {d:>10.1}\n", .{ z.min, z.avg });
        std.debug.print("  zimple-ve       {d:>10.1} {d:>10.1}  {d:.2}x\n\n", .{ m.min, m.avg, m.avg / z.avg });
    }

    // Multiview
    {
        const z = try timeOne(runMvZ);
        const m = try timeOne(runMvM);
        std.debug.print("  zig-mv          {d:>10.1} {d:>10.1}\n", .{ z.min, z.avg });
        std.debug.print("  zimple-mv       {d:>10.1} {d:>10.1}  {d:.2}x\n\n", .{ m.min, m.avg, m.avg / z.avg });
    }
}
