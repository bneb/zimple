const std = @import("std");
const zimple = @import("zimple");

const IntCtx = zimple.hamt.HashContext(i32){
    .hash = struct {
        fn h(k: i32) u64 {
            return @as(u64, @bitCast(@as(i64, k))) *% 11400714819323198485;
        }
    }.h,
    .eql = struct {
        fn e(a: i32, b: i32) bool { return a == b; }
    }.e,
};

const ZMap = std.AutoHashMap(i32, i32);
const HMap = zimple.hamt.HashMap(i32, i32, IntCtx);

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
const alloc_g = std.heap.page_allocator;
const N = 100_000;

var keys: []i32 = &.{};
var zig_map: ZMap = undefined;
var zim_map: HMap = undefined;

var pool: *zimple.ThreadPoolExecutor = undefined;

fn setup() !void {
    var arena = std.heap.ArenaAllocator.init(alloc_g);
    const aa = arena.allocator();
    
    keys = try alloc_g.alloc(i32, N);
    
    zig_map = ZMap.init(alloc_g);
    zim_map = HMap.empty(aa);

    var i: i32 = 0;
    while (i < N) : (i += 1) {
        keys[@intCast(i)] = i * 3;
        try zig_map.put(keys[@intCast(i)], i);
        zim_map = try zim_map.put(keys[@intCast(i)], i);
    }
    
    pool = try zimple.ThreadPoolExecutor.init(alloc_g, 4);
}

fn benchZigIter() !void {
    var sum: i64 = 0;
    var it = zig_map.iterator();
    while (it.next()) |entry| {
        sum += @as(i64, entry.value_ptr.*);
    }
    std.mem.doNotOptimizeAway(sum);
}

fn benchZimpleParReduce() !void {
    const reduce_fn = struct { fn f(k: i32, v: i32) i64 { _ = k; return @as(i64, v); } }.f;
    const merge_fn = struct { fn f(a: i64, b: i64) i64 { return a + b; } }.f;
    const sum = try zimple.parReduce(i32, i32, IntCtx, i64, pool.executor(), zim_map.root, reduce_fn, merge_fn, 0);
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    io_g = init.io;
    try setup();
    defer pool.deinit();
    
    std.debug.print("\n=== Adaptive Chunking parReduce (N={d}, ReleaseFast) ===\n\n", .{N});
    std.debug.print("  {s:<20} {s:>10} {s:>10} {s:>7}\n", .{ "benchmark", "min(us)", "avg(us)", "ratio" });
    std.debug.print("  {s:-<20} {s:-<10} {s:-<10} {s:-<7}\n", .{ "", "", "", "" });

    const z = try timeOne(benchZigIter);
    const m = try timeOne(benchZimpleParReduce);
    
    std.debug.print("  zig-iter             {d:>10.1} {d:>10.1}\n", .{ z.min, z.avg });
    std.debug.print("  zimple-parReduce     {d:>10.1} {d:>10.1}  {d:.2}x\n\n", .{ m.min, m.avg, m.avg / z.avg });
}
