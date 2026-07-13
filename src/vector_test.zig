const std = @import("std");
const Vector = @import("vector.zig").Vector;
const testing = std.testing;

test "empty vector" {
    const V = Vector(i32);
    const v = V.empty(testing.allocator);
    try testing.expect(v.isEmpty());
    try testing.expectEqual(@as(usize, 0), v.len());
    try testing.expectEqual(null, v.get(0));
}

test "pushBack and get" {
    const V = Vector(i32);
    var v = V.empty(testing.allocator);
    v = try v.pushBack(10);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.len());
    try testing.expectEqual(@as(i32, 10), v.get(0).?);
    try testing.expectEqual(null, v.get(1));
}

test "pushBack 100 elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    defer v.deinit();
    try testing.expectEqual(@as(usize, 100), v.len());
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(i32, @intCast(i)), v.get(i).?);
    }
}

test "pushBack across leaf boundary (32+ elements)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    defer v.deinit();
    try testing.expectEqual(@as(usize, 65), v.len());
    try testing.expectEqual(@as(i32, 0), v.get(0).?);
    try testing.expectEqual(@as(i32, 31), v.get(31).?);
    try testing.expectEqual(@as(i32, 32), v.get(32).?);
    try testing.expectEqual(@as(i32, 64), v.get(64).?);
    try testing.expectEqual(null, v.get(65));
}

test "set: structural sharing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    const v2 = try v.set(25, 999);
    defer v2.deinit();
    try testing.expectEqual(@as(i32, 25), v.get(25).?);
    try testing.expectEqual(@as(i32, 999), v2.get(25).?);
    try testing.expectEqual(@as(i32, 0), v2.get(0).?);
    try testing.expectEqual(@as(i32, 49), v2.get(49).?);
}

test "structural sharing: memory proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    const v2 = try v.set(25, 999);
    defer v2.deinit();
    const v_root = v.root.?;
    const v2_root = v2.root.?;
    switch (v_root.*) {
        .internal => |vi| {
            switch (v2_root.*) {
                .internal => |v2i| {
                    try testing.expectEqual(vi.slots[1], v2i.slots[1]);
                },
                .leaf => {},
            }
        },
        .leaf => {},
    }
}

test "set at leaf boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    const v2 = try v.set(31, 999);
    defer v2.deinit();
    try testing.expectEqual(@as(i32, 999), v2.get(31).?);
    try testing.expectEqual(@as(i32, 30), v2.get(30).?);
    try testing.expectEqual(@as(i32, 32), v2.get(32).?);
}

test "set index out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    v = try v.pushBack(1);
    defer v.deinit();
    try testing.expectError(error.IndexOutOfBounds, v.set(1, 2));
    try testing.expectError(error.IndexOutOfBounds, v.set(5, 2));
}

test "pushBack across internal boundary (1024+)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 1100) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1100), v.len());
    try testing.expectEqual(@as(i32, 0), v.get(0).?);
    try testing.expectEqual(@as(i32, 1023), v.get(1023).?);
    try testing.expectEqual(@as(i32, 1024), v.get(1024).?);
    try testing.expectEqual(@as(i32, 1099), v.get(1099).?);
}

test "iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        v = try v.pushBack(@intCast(i));
    }
    defer v.deinit();
    var it = v.iterator();
    i = 0;
    while (it.next()) |elem| {
        try testing.expectEqual(@as(i32, @intCast(i)), elem);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 50), i);
}

test "iterator empty" {
    const V = Vector(i32);
    const v = V.empty(testing.allocator);
    var it = v.iterator();
    try testing.expectEqual(null, it.next());
}

test "single element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    v = try v.pushBack(42);
    defer v.deinit();
    try testing.expectEqual(@as(i32, 42), v.get(0).?);
    try testing.expectEqual(null, v.get(1));
    const v2 = try v.set(0, 99);
    defer v2.deinit();
    try testing.expectEqual(@as(i32, 42), v.get(0).?);
    try testing.expectEqual(@as(i32, 99), v2.get(0).?);
}

test "set on empty vector" {
    const V = Vector(i32);
    const v = V.empty(testing.allocator);
    try testing.expectError(error.EmptyVector, v.set(0, 42));
}

test "get on edge indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    v = try v.pushBack(1);
    defer v.deinit();
    try testing.expectEqual(null, v.get(1));
    try testing.expectEqual(null, v.get(100));
}

test "iterator on single element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    v = try v.pushBack(7);
    defer v.deinit();
    var it = v.iterator();
    try testing.expectEqual(@as(i32, 7), it.next().?);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(null, it.next());
}

test "deinit on empty vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = Vector(i32);
    var v = V.empty(arena.allocator());
    v.deinit(); // should not crash
}
