const std = @import("std");
const vec_mod = @import("vector.zig");

/// Wrap a vector iterator, applying `f` to each element.
/// Returns a struct with `.next()` → `?Output`.
pub fn mapIter(inner: anytype, f: anytype) MapIter(@TypeOf(inner), @TypeOf(f)) {
    return .{ .inner = inner, .f = f };
}

pub fn MapIter(comptime Inner: type, comptime F: type) type {
    return struct {
        inner: Inner,
        f: F,

        pub fn next(self: *@This()) ?MapOut(Inner, F) {
            const v = self.inner.next() orelse return null;
            return self.f.call(v);
        }
    };
}

/// Wrap a vector iterator, skipping elements that don't match `pred`.
pub fn filterIter(inner: anytype, pred: anytype) FilterIter(@TypeOf(inner), @TypeOf(pred)) {
    return .{ .inner = inner, .pred = pred };
}

pub fn FilterIter(comptime Inner: type, comptime Pred: type) type {
    return struct {
        inner: Inner,
        pred: Pred,
        const T = ChildType(Inner);

        pub fn next(self: *@This()) ?T {
            while (self.inner.next()) |v| {
                if (self.pred.call(v)) return v;
            }
            return null;
        }
    };
}

/// Materialize a lazy iterator into a Vector.
pub fn collect(iter: anytype, allocator: std.mem.Allocator) !vec_mod.Vector(ChildType(@TypeOf(iter))) {
    var result = vec_mod.Vector(ChildType(@TypeOf(iter))).empty(allocator);
    var it = iter;
    while (it.next()) |v| {
        result = try result.pushBack(v);
    }
    return result;
}

/// Reduce a lazy iterator to a scalar (consumes the iterator).
pub fn fold(iter: anytype, comptime Acc: type, initial: Acc, f: anytype) Acc {
    var acc = initial;
    var it = iter;
    while (it.next()) |v| {
        acc = f.call(acc, v);
    }
    return acc;
}

/// Create a lazy pipeline from a vector.
pub fn lazy(vec: anytype) MapIter(@TypeOf(vec.iterator()), Identity(@TypeOf(vec).Element)) {
    const Id = Identity(@TypeOf(vec).Element);
    return mapIter(vec.iterator(), Id{});
}

fn Identity(comptime T: type) type {
    return struct {
        pub fn call(_: @This(), x: T) T { return x; }
    };
}

// ── Type helpers ──

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

fn MapOut(comptime Inner: type, comptime F: type) type {
    const D = Deref(Inner);
    const elem = @typeInfo(@typeInfo(@TypeOf(@field(D, "next"))).@"fn".return_type.?).optional.child;
    return @TypeOf(@call(.auto, @field(F, "call"), .{ @as(F, undefined), @as(elem, undefined) }));
}

fn ChildType(comptime It: type) type {
    const D = Deref(It);
    return @typeInfo(@typeInfo(@TypeOf(@field(D, "next"))).@"fn".return_type.?).optional.child;
}

// ── Tests ──

const testing = std.testing;

test "iter: map transforms elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer vec.deinit();

    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };

    var it = mapIter(vec.iterator(), Square{});
    try testing.expectEqual(@as(i32, 1), it.next().?);
    try testing.expectEqual(@as(i32, 4), it.next().?);
    try testing.expectEqual(@as(i32, 9), it.next().?);
    try testing.expect(it.next() == null);
}

test "iter: filter skips non-matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vec.deinit();

    const IsEven = struct {
        pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) == 0; }
    };

    var it = filterIter(vec.iterator(), IsEven{});
    try testing.expectEqual(@as(i32, 2), it.next().?);
    try testing.expectEqual(@as(i32, 4), it.next().?);
    try testing.expect(it.next() == null);
}

test "iter: filter + map chained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vec.deinit();

    const IsOdd = struct {
        pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; }
    };
    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };

    var filtered = filterIter(vec.iterator(), IsOdd{});
    var mapped = mapIter(&filtered, Square{});
    try testing.expectEqual(@as(i32, 1), mapped.next().?);  // 1^2
    try testing.expectEqual(@as(i32, 9), mapped.next().?);  // 3^2
    try testing.expectEqual(@as(i32, 25), mapped.next().?); // 5^2
    try testing.expect(mapped.next() == null);
}

test "iter: collect materializes into vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vec.deinit();

    const IsEven = struct {
        pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) == 0; }
    };
    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };

    var filtered = filterIter(vec.iterator(), IsEven{});
    var mapped = mapIter(&filtered, Square{});
    const result = try collect(&mapped, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.len());
    try testing.expectEqual(@as(i32, 4), result.get(0).?);  // 2^2
    try testing.expectEqual(@as(i32, 16), result.get(1).?); // 4^2
}

test "iter: fold reduces to scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4 });
    defer vec.deinit();

    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };
    const Add = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 { return acc + x; }
    };

    var mapped = mapIter(vec.iterator(), Square{});
    try testing.expectEqual(@as(i32, 30), fold(&mapped, i32, 0, Add{}));
}

test "iter: empty vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = vec_mod.Vector(i32).empty(arena.allocator());
    var it = mapIter(vec.iterator(), struct {
        pub fn call(_: @This(), x: i32) i32 { return x * 2; }
    }{});
    try testing.expect(it.next() == null);
}
