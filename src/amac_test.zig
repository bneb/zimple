const std = @import("std");
const testing = std.testing;
const amac = @import("amac.zig");
const hamt = @import("hamt.zig");

const IntCtx = hamt.HashContext(i32){
    .hash = struct {
        fn h(k: i32) u64 {
            return @as(u64, @bitCast(@as(i64, k))) *% 11400714819323198485;
        }
    }.h,
    .eql = struct {
        fn e(a: i32, b: i32) bool {
            return a == b;
        }
    }.e,
};

const HMap = hamt.HashMap(i32, i32, IntCtx);
const AmacEngine = amac.AmacEngine(i32, i32, IntCtx, 32); // Batch size 32

test "amac: bulk get" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = HMap.empty(arena.allocator());

    // Populate the map
    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        map = try map.put(i, i * 2);
    }

    var keys: [1000]i32 = undefined;
    var results: [1000]?i32 = undefined;
    i = 0;
    while (i < 1000) : (i += 1) {
        keys[@intCast(i)] = i;
        results[@intCast(i)] = null; // clear
    }

    // Also ask for keys that aren't there
    keys[999] = 2000;
    
    // Perform bulk lookup
    AmacEngine.bulkGet(map.root, &keys, &results);

    i = 0;
    while (i < 999) : (i += 1) {
        try testing.expectEqual(@as(?i32, i * 2), results[@intCast(i)]);
    }
    // Key 2000 is not in the map
    try testing.expectEqual(@as(?i32, null), results[999]);
}

test "amac: empty root" {
    var keys = [_]i32{ 1, 2, 3 };
    var results = [_]?i32{ 42, 42, 42 };
    
    AmacEngine.bulkGet(null, &keys, &results);
    
    for (results) |res| {
        try testing.expectEqual(@as(?i32, null), res);
    }
}
