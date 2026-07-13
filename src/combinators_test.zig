const std = @import("std");
const c = @import("combinators.zig");
const list_mod = @import("list.zig");
const vec_mod = @import("vector.zig");
const testing = std.testing;

test "mapList: i32 to i32" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(2);
    list = try list.cons(1);
    defer list.deinit();

    const Doubler = struct {
        factor: i32,
        pub fn call(self: @This(), x: i32) i32 {
            return self.factor * x;
        }
    };
    const f = Doubler{ .factor = 10 };

    const mapped = try c.mapList(i32, list, f, testing.allocator);
    defer mapped.deinit();
    try testing.expectEqual(@as(i32, 10), mapped.head().?);
    try testing.expectEqual(@as(i32, 20), mapped.tail().?.head().?);
    try testing.expectEqual(@as(i32, 30), mapped.tail().?.tail().?.head().?);
}

test "mapList: i32 to []const u8" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(2);
    list = try list.cons(1);
    defer list.deinit();

    const Labeler = struct {
        prefix: []const u8,
        pub fn call(self: @This(), x: i32) []const u8 {
            _ = x;
            return self.prefix;
        }
    };
    const f = Labeler{ .prefix = "n=" };

    const mapped = try c.mapList([]const u8, list, f, testing.allocator);
    defer mapped.deinit();
    try testing.expectEqual(@as(usize, 3), mapped.len());
}

test "mapList: empty list" {
    const L = list_mod.List(i32);
    const list = L.empty(testing.allocator);

    const Doubler = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    const f = Doubler{};

    const mapped = try c.mapList(i32, list, f, testing.allocator);
    defer mapped.deinit();
    try testing.expect(mapped.isEmpty());
}

test "filterList: keep evens" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    var i: usize = 0;
    while (i < 6) : (i += 1) list = try list.cons(@intCast(5 - i));
    defer list.deinit();

    const IsEven = struct {
        pub fn call(_: @This(), x: i32) bool {
            return @mod(x, 2) == 0;
        }
    };
    const pred = IsEven{};

    const filtered = try c.filterList(list, pred, testing.allocator);
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 3), filtered.len());
    try testing.expectEqual(@as(i32, 0), filtered.head().?);
    try testing.expectEqual(@as(i32, 2), filtered.tail().?.head().?);
    try testing.expectEqual(@as(i32, 4), filtered.tail().?.tail().?.head().?);
}

test "filterList: empty list" {
    const L = list_mod.List(i32);
    const list = L.empty(testing.allocator);

    const Always = struct {
        pub fn call(_: @This(), x: i32) bool {
            _ = x;
            return true;
        }
    };
    const pred = Always{};

    const filtered = try c.filterList(list, pred, testing.allocator);
    defer filtered.deinit();
    try testing.expect(filtered.isEmpty());
}

test "filterList: none match" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(5);
    defer list.deinit();

    const Gt100 = struct {
        pub fn call(_: @This(), x: i32) bool {
            return x > 100;
        }
    };
    const pred = Gt100{};

    const filtered = try c.filterList(list, pred, testing.allocator);
    defer filtered.deinit();
    try testing.expect(filtered.isEmpty());
}

test "reduceList: sum with capture" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(4);
    list = try list.cons(3);
    list = try list.cons(2);
    list = try list.cons(1);
    defer list.deinit();

    const ScaledSum = struct {
        mult: i32,
        pub fn call(self: @This(), acc: i32, x: i32) i32 {
            return acc + self.mult * x;
        }
    };
    const f = ScaledSum{ .mult = 1 };

    try testing.expectEqual(@as(i32, 10), c.reduceList(list, f, @as(i32, 0)));
}

test "reduceList: empty returns initial" {
    const L = list_mod.List(i32);
    const list = L.empty(testing.allocator);

    const AddOne = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 {
            _ = x;
            return acc + 1;
        }
    };
    const f = AddOne{};

    try testing.expectEqual(@as(i32, 42), c.reduceList(list, f, @as(i32, 42)));
}

test "bindList: flatMap" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(1);
    defer list.deinit();

    const Dup = struct {
        alloc: std.mem.Allocator,
        pub fn call(self: @This(), x: i32) L {
            var inner = L.empty(self.alloc);
            inner = inner.cons(x + 1) catch unreachable;
            inner = inner.cons(x) catch unreachable;
            return inner;
        }
    };
    const f = Dup{ .alloc = testing.allocator };

    const bound = try c.bindList(i32, list, f, testing.allocator);
    defer bound.deinit();
    try testing.expectEqual(@as(usize, 4), bound.len());
    try testing.expectEqual(@as(i32, 1), bound.head().?);
    try testing.expectEqual(@as(i32, 2), bound.tail().?.head().?);
    try testing.expectEqual(@as(i32, 3), bound.tail().?.tail().?.head().?);
    try testing.expectEqual(@as(i32, 4), bound.tail().?.tail().?.tail().?.head().?);
}

test "mapVec: vector transformation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    var vec = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 10) : (i += 1) vec = try vec.pushBack(@intCast(i));
    defer vec.deinit();

    const Offset = struct {
        factor: i32,
        pub fn call(self: @This(), x: i32) i32 {
            return self.factor + x;
        }
    };
    const f = Offset{ .factor = 100 };

    const mapped = try c.mapVec(i32, vec, f, arena.allocator());
    defer mapped.deinit();
    try testing.expectEqual(@as(usize, 10), mapped.len());
    try testing.expectEqual(@as(i32, 100), mapped.get(0).?);
    try testing.expectEqual(@as(i32, 109), mapped.get(9).?);
}

test "mapVec: empty vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    const vec = V.empty(arena.allocator());

    const Doubler = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    const f = Doubler{};

    const mapped = try c.mapVec(i32, vec, f, arena.allocator());
    defer mapped.deinit();
    try testing.expect(mapped.isEmpty());
}

test "filterVec: remove evens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    var vec = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 10) : (i += 1) vec = try vec.pushBack(@intCast(i));
    defer vec.deinit();

    const IsOdd = struct {
        pub fn call(_: @This(), x: i32) bool {
            return @mod(x, 2) != 0;
        }
    };
    const pred = IsOdd{};

    const filtered = try c.filterVec(vec, pred, arena.allocator());
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 5), filtered.len());
    try testing.expectEqual(@as(i32, 1), filtered.get(0).?);
    try testing.expectEqual(@as(i32, 9), filtered.get(4).?);
}

test "reduceVec: vector sum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    var vec = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 10) : (i += 1) vec = try vec.pushBack(@intCast(i));
    defer vec.deinit();

    const Add = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 {
            return acc + x;
        }
    };
    const f = Add{};

    try testing.expectEqual(@as(i32, 45), c.reduceVec(vec, f, @as(i32, 0)));
}

test "bindVec: flatMap over vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    var vec = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 4) : (i += 1) vec = try vec.pushBack(@intCast(i));
    defer vec.deinit();

    const Dup = struct {
        pub fn call(_: @This(), x: i32) V {
            var inner = V.empty(std.heap.page_allocator);
            inner = inner.pushBack(x) catch unreachable;
            inner = inner.pushBack(x * 10) catch unreachable;
            return inner;
        }
    };
    const f = Dup{};

    const bound = try c.bindVec(i32, vec, f, arena.allocator());
    defer bound.deinit();
    // [0, 0, 1, 10, 2, 20, 3, 30]
    try testing.expectEqual(@as(usize, 8), bound.len());
    try testing.expectEqual(@as(i32, 0), bound.get(0).?);
    try testing.expectEqual(@as(i32, 0), bound.get(1).?);
    try testing.expectEqual(@as(i32, 10), bound.get(3).?);
    try testing.expectEqual(@as(i32, 30), bound.get(7).?);
}

test "chained pipeline: filter → map → reduce" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    var i: usize = 0;
    while (i < 10) : (i += 1) list = try list.cons(@intCast(9 - i));
    defer list.deinit();

    const IsEven = struct {
        pub fn call(_: @This(), x: i32) bool {
            return @mod(x, 2) == 0;
        }
    };
    const pred = IsEven{};

    const filtered = try c.filterList(list, pred, testing.allocator);
    defer filtered.deinit();

    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    const mapper = Double{};
    const mapped = try c.mapList(i32, filtered, mapper, testing.allocator);
    defer mapped.deinit();

    const Add = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 {
            return acc + x;
        }
    };
    const reducer = Add{};
    try testing.expectEqual(@as(i32, 40), c.reduceList(mapped, reducer, @as(i32, 0)));
}
