const std = @import("std");
const testing = std.testing;
const par = @import("par.zig");
const hamt = @import("hamt.zig");
const chamt = @import("concurrent_hamt.zig");

const IntCtx = hamt.HashContext(i32){
    .hash = struct {
        fn h(k: i32) u64 {
            return @as(u64, @bitCast(@as(i64, k))) *% 11400714819323198485;
        }
    }.h,
    .eql = struct {
        fn e(a: i32, b: i32) bool { return a == b; }
    }.e,
};

const CHMap = chamt.ConcurrentHashMap(i32, i32, IntCtx);

fn sumReduce(k: i32, v: i32) i64 {
    _ = k;
    return v;
}

fn sumMerge(a: i64, b: i64) i64 {
    return a + b;
}

fn doubleMap(k: i32, v: i32) i32 {
    _ = k;
    return v * 2;
}

test "par: parReduce and parMap" {
    var map = CHMap.init(testing.allocator);
    defer map.deinit();

    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        try map.put(i, i * 2);
    }

    const snap = map.snapshot();

    var tp = try par.ThreadPoolExecutor.init(testing.allocator, 4);
    defer tp.deinit();

    const sum = try par.parReduce(i32, i32, IntCtx, i64, tp.executor(), snap.root, sumReduce, sumMerge, 0);

    // 0 + 2 + 4 + ... + 1998
    // sum(0..999) * 2 = (999 * 1000 / 2) * 2 = 999000
    try testing.expectEqual(@as(i64, 999000), sum);

    const mapped = try par.parMap(i32, i32, IntCtx, i32, testing.allocator, tp.executor(), snap.root, doubleMap);
    defer {
        // Mapped tree will be a pure immutable hamt
        // We can just deinit it
        mapped.deinit();
    }
    
    // map(x) = x * 2, so the value for key i should be i * 4
    i = 0;
    while (i < 1000) : (i += 1) {
        try testing.expectEqual(@as(?i32, i * 4), mapped.get(i));
    }
}
