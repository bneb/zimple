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

const ZigCtx = struct {
    pub fn hash(_: @This(), k: i32) u64 {
        return @as(u64, @bitCast(@as(i64, k))) *% 11400714819323198485;
    }
    pub fn eql(_: @This(), a: i32, b: i32) bool { return a == b; }
};

const ZMap = std.HashMap(i32, i32, ZigCtx, std.hash_map.default_max_load_percentage);
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
var out_results: []?i32 = &.{};

fn setup() !void {
    var arena = std.heap.ArenaAllocator.init(alloc_g);
    const aa = arena.allocator();
    
    keys = try alloc_g.alloc(i32, N);
    out_results = try alloc_g.alloc(?i32, N);
    
    zig_map = ZMap.init(alloc_g);
    zim_map = HMap.empty(aa);

    var i: i32 = 0;
    while (i < N) : (i += 1) {
        keys[@intCast(i)] = i * 3;
        try zig_map.put(keys[@intCast(i)], i);
        zim_map = try zim_map.put(keys[@intCast(i)], i);
    }
    
    // Shuffle the keys to ensure we aren't artificially benefiting from arena insertion order cache locality
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    random.shuffle(i32, keys);
}

fn benchZigGet() !void {
    for (keys, 0..) |k, i| {
        out_results[i] = zig_map.get(k);
    }
}

fn benchZimpleGet() !void {
    for (keys, 0..) |k, i| {
        out_results[i] = zim_map.get(k);
    }
}

fn benchZimpleBulkGet() !void {
    zim_map.bulkGet(32, keys, out_results);
}

pub fn main(init: std.process.Init) !void {
    io_g = init.io;
    try setup();
    
    std.debug.print("\n=== Single-Threaded HAMT Performance (N={d}, ReleaseFast) ===\n\n", .{N});
    std.debug.print("  {s:<20} {s:>10} {s:>10} {s:>7}\n", .{ "benchmark", "min(us)", "avg(us)", "ratio" });
    std.debug.print("  {s:-<20} {s:-<10} {s:-<10} {s:-<7}\n", .{ "", "", "", "" });

    const z = try timeOne(benchZigGet);
    const m = try timeOne(benchZimpleGet);
    const m_bulk = try timeOne(benchZimpleBulkGet);
    
    std.debug.print("  zig-get              {d:>10.1} {d:>10.1}\n", .{ z.min, z.avg });
    std.debug.print("  zimple-get           {d:>10.1} {d:>10.1}  {d:.2}x\n", .{ m.min, m.avg, m.avg / z.avg });
    std.debug.print("  zimple-bulkGet(AMAC) {d:>10.1} {d:>10.1}  {d:.2}x\n\n", .{ m_bulk.min, m_bulk.avg, m_bulk.avg / z.avg });
}
