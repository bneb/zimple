const std = @import("std");
const vec_mod = @import("vector.zig");
const c = @import("combinators.zig");
const lazy_mod = @import("lazy.zig");

// ── Type-inferred combinators for Vector ───────────────────────────────────
//
// These wrap the explicit combinators (mapVec, filterVec, etc.) and use
// comptime type extraction to infer what the compiler already knows.

/// Map over a vector — return type inferred from the callable.
///
/// ```zig
/// const squares = try map(vec, Square{}, alloc);
/// // vs: const squares = try mapVec(i32, vec, Square{}, alloc);
/// ```
pub fn map(vec: anytype, f: anytype, allocator: std.mem.Allocator) !vec_mod.Vector(MapOut(@TypeOf(vec), @TypeOf(f))) {
    return c.mapVec(MapOut(@TypeOf(vec), @TypeOf(f)), vec, f, allocator);
}

/// Filter a vector — same type, no annotation needed.
pub fn filter(vec: anytype, pred: anytype, allocator: std.mem.Allocator) !@TypeOf(vec) {
    return c.filterVec(vec, pred, allocator);
}

/// Flat-map (bind) over a vector. The callable returns `Vector(U)`;
/// `U` is extracted automatically.
pub fn bind(vec: anytype, f: anytype, allocator: std.mem.Allocator) !vec_mod.Vector(BindOut(@TypeOf(vec), @TypeOf(f))) {
    return c.bindVec(BindOut(@TypeOf(vec), @TypeOf(f)), vec, f, allocator);
}

/// Reduce — already inferred via the initial value type.
pub const reduce = c.reduceVec;

/// filterMap — T inferred from vec, U from the Option return type.
pub fn filterMap(vec: anytype, f: anytype, allocator: std.mem.Allocator) !vec_mod.Vector(MapOut(@TypeOf(vec), @TypeOf(f))) {
    return @import("maybe.zig").filterMapVec(MapOut(@TypeOf(vec), @TypeOf(f)), vec, f, allocator);
}

// ── Type-inferred Pipeline ─────────────────────────────────────────────────

/// Create a lazy pipeline — no allocation until fold/collect.
pub fn pipeline(vec: anytype) lazy_mod.Lazy(@TypeOf(vec).Element) {
    return lazy_mod.init(vec);
}

// ── Comptime type helpers ──────────────────────────────────────────────────

/// What does `f.call(t)` return, where `t` is the element type of Src?
fn MapOut(comptime Src: type, comptime F: type) type {
    const T = Src.Element;
    return @TypeOf(@call(.auto, @field(F, "call"), .{ @as(F, undefined), @as(T, undefined) }));
}

/// Element type of the Vector that `f.call(t)` returns (for bind).
fn BindOut(comptime Src: type, comptime F: type) type {
    const InnerVec = MapOut(Src, F);
    return InnerVec.Element;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "infer: map auto-detects output type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer vec.deinit();

    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };
    const result = try map(vec, Square{}, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), result.get(0).?);
    try testing.expectEqual(@as(i32, 4), result.get(1).?);
    try testing.expectEqual(@as(i32, 9), result.get(2).?);
}

test "infer: map changes element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer vec.deinit();

    const ToStr = struct {
        pub fn call(_: @This(), x: i32) []const u8 {
            _ = x;
            return "x";
        }
    };
    const result = try map(vec, ToStr{}, arena.allocator());
    defer result.deinit();

    try testing.expectEqualStrings("x", result.get(0).?);
    try testing.expectEqual(@as(usize, 3), result.len());
}

test "infer: filter preserves type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5, 6 });
    defer vec.deinit();

    const IsEven = struct {
        pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) == 0; }
    };
    const result = try filter(vec, IsEven{}, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.len());
    try testing.expectEqual(@as(i32, 2), result.get(0).?);
    try testing.expectEqual(@as(i32, 6), result.get(2).?);
}

test "infer: reduce uses initial value type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4 });
    defer vec.deinit();

    const Add = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 { return acc + x; }
    };
    try testing.expectEqual(@as(i32, 10), reduce(vec, Add{}, @as(i32, 0)));
}

test "infer: bind auto-detects inner element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2 });
    defer vec.deinit();

    const Dup = struct {
        pub fn call(_: @This(), x: i32) vec_mod.Vector(i32) {
            var inner = vec_mod.Vector(i32).empty(std.heap.page_allocator);
            inner = inner.pushBack(x) catch unreachable;
            inner = inner.pushBack(x * 10) catch unreachable;
            return inner;
        }
    };
    const result = try bind(vec, Dup{}, arena.allocator());
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.len());
    try testing.expectEqual(@as(i32, 1), result.get(0).?);
    try testing.expectEqual(@as(i32, 10), result.get(1).?);
    try testing.expectEqual(@as(i32, 2), result.get(2).?);
    try testing.expectEqual(@as(i32, 20), result.get(3).?);
}

test "infer: pipeline — lazy chain, zero allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vec.deinit();

    const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
    const Square = struct { pub fn call(_: @This(), x: i32) i32 { return x * x; } };
    const Add = struct { pub fn call(_: @This(), acc: i32, x: i32) i32 { return acc + x; } };

    const result = pipeline(vec).filter(IsOdd{}).map(i32, Square{}).fold(i32, 0, Add{});
    try testing.expectEqual(@as(i32, 35), result);
}
