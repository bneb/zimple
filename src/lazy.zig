// Lazy composable pipeline — filter/map/fold in one pass. Zero intermediate
// allocations. Each step returns a new comptime type; the terminal `fold`
// drives a single traversal through the combined operations.
const std = @import("std");
const vec_mod = @import("vector.zig");

/// Wrap a Vector in a lazy chain.
pub fn init(vec: anytype) Lazy(@TypeOf(vec).Element) {
    return Lazy(@TypeOf(vec).Element){ .src = vec };
}

pub fn Lazy(comptime T: type) type {
    return struct {
        pub const Element = T;
        src: vec_mod.Vector(T),

        pub fn filter(self: @This(), pred: anytype) LazyFilter(@This(), T, @TypeOf(pred)) {
            return .{ .inner = self, .pred = pred };
        }

        pub fn map(self: @This(), comptime U: type, f: anytype) LazyMap(@This(), U, @TypeOf(f)) {
            return .{ .inner = self, .f = f };
        }

        // Called by fold to drive iteration from the source.
        pub fn fold(self: @This(), comptime Acc: type, initial: Acc, f: anytype) Acc {
            var acc = initial;
            var it = self.src.iterator();
            while (it.next()) |elem| acc = f.call(acc, elem);
            return acc;
        }
    };
}

fn LazyFilter(comptime Inner: type, comptime T: type, comptime Pred: type) type {
    return struct {
        inner: Inner,
        pred: Pred,

        pub fn filter(self: @This(), pred2: anytype) LazyFilter(@This(), T, @TypeOf(pred2)) {
            return .{ .inner = self, .pred = pred2 };
        }

        pub fn map(self: @This(), comptime U: type, f: anytype) LazyMap(@This(), U, @TypeOf(f)) {
            return .{ .inner = self, .f = f };
        }

        pub fn fold(self: @This(), comptime Acc: type, initial: Acc, f: anytype) Acc {
            // Rewrite f to incorporate the filter predicate, then delegate
            const Wrapped = struct {
                pred2: Pred,
                inner_f: @TypeOf(f),
                fn call(self2: @This(), acc2: Acc, elem: T) Acc {
                    if (self2.pred2.call(elem)) return self2.inner_f.call(acc2, elem);
                    return acc2;
                }
            };
            return self.inner.fold(Acc, initial, Wrapped{ .pred2 = self.pred, .inner_f = f });
        }
    };
}

fn LazyMap(comptime Inner: type, comptime U: type, comptime F: type) type {
    return struct {
        inner: Inner,
        f: F,

        pub fn filter(self: @This(), pred: anytype) LazyFilter(@This(), U, @TypeOf(pred)) {
            return .{ .inner = self, .pred = pred };
        }

        pub fn map(self: @This(), comptime U2: type, f2: anytype) LazyMap(@This(), U2, @TypeOf(f2)) {
            return .{ .inner = self, .f = f2 };
        }

        pub fn fold(self: @This(), comptime Acc: type, initial: Acc, f: anytype) Acc {
            // Wrap f to apply map before the fold function
            const Wrapped = struct {
                mapper: F,
                inner_f: @TypeOf(f),
                fn call(self2: @This(), acc2: Acc, elem: InnerElem(Inner)) Acc {
                    return self2.inner_f.call(acc2, self2.mapper.call(elem));
                }
            };
            return self.inner.fold(Acc, initial, Wrapped{ .mapper = self.f, .inner_f = f });
        }
    };
}

fn InnerElem(comptime T: type) type {
    if (@hasDecl(T, "Element")) return T.Element;
    return InnerElem(@TypeOf(@field(@as(T, undefined), "inner")));
}

// ── Tests ──

const testing = std.testing;

test "lazy: filter → fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vec.deinit();
    const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
    const Add = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };
    const result = init(vec).filter(IsOdd{}).fold(i32, 0, Add{});
    try testing.expectEqual(@as(i32, 9), result);
}

test "lazy: map → fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer vec.deinit();
    const Square = struct { pub fn call(_: @This(), x: i32) i32 { return x * x; } };
    const Add = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };
    const result = init(vec).map(i32, Square{}).fold(i32, 0, Add{});
    try testing.expectEqual(@as(i32, 14), result);
}

test "lazy: filter → map → fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    defer vec.deinit();
    const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
    const Square = struct { pub fn call(_: @This(), x: i32) i32 { return x * x; } };
    const Add = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };
    const result = init(vec).filter(IsOdd{}).map(i32, Square{}).fold(i32, 0, Add{});
    try testing.expectEqual(@as(i32, 165), result);
}

test "lazy: double filter → map → fold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    defer vec.deinit();
    const Gt2 = struct { pub fn call(_: @This(), x: i32) bool { return x > 2; } };
    const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
    const Square = struct { pub fn call(_: @This(), x: i32) i32 { return x * x; } };
    const Add = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };
    const result = init(vec).filter(Gt2{}).filter(IsOdd{}).map(i32, Square{}).fold(i32, 0, Add{});
    try testing.expectEqual(@as(i32, 164), result);
}

test "lazy: map changes type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec = try vec_mod.Vector(i32).fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer vec.deinit();
    const ToF64 = struct { pub fn call(_: @This(), x: i32) f64 { return @floatFromInt(x); } };
    const AddF = struct { pub fn call(_: @This(), a: f64, b: f64) f64 { return a + b; } };
    const result = init(vec).map(f64, ToF64{}).fold(f64, 0.0, AddF{});
    try testing.expectEqual(@as(f64, 6.0), result);
}
