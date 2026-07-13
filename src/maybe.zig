const std = @import("std");

/// Option(T) — a value that may or may not be present.
///
/// Use `destructure()` with Zig's native `switch` for exhaustive matching:
/// ```
/// switch (opt.destructure()) {
///     .some => |v| ...,
///     .none => ...,
/// }
/// ```
pub fn Option(comptime T: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        const Inner = union(enum) {
            some: T,
            none: void,
        };

        /// View for destructuring with switch.
        pub const View = union(enum) {
            some: T,
            none: void,
        };

        pub fn some(value: T) Self {
            return .{ .inner = .{ .some = value } };
        }

        pub fn none() Self {
            return .{ .inner = .none };
        }

        pub fn isSome(self: Self) bool {
            return self.inner == .some;
        }

        pub fn isNone(self: Self) bool {
            return self.inner == .none;
        }

        /// Unwrap or return a default.
        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self.inner) {
                .some => |v| v,
                .none => default,
            };
        }

        /// Transform the inner value if present.
        pub fn map(self: Self, f: anytype) Option(@TypeOf(f.call(self.inner.some))) {
            return switch (self.inner) {
                .some => |v| .{ .inner = .{ .some = f.call(v) } },
                .none => .{ .inner = .none },
            };
        }

        /// Flat-map: chain an operation that may itself return none.
        pub fn bind(self: Self, f: anytype) @TypeOf(f.call(self.inner.some)) {
            return switch (self.inner) {
                .some => |v| f.call(v),
                .none => @TypeOf(f.call(self.inner.some)).none(),
            };
        }

        /// Return a tagged union for exhaustive switch matching.
        pub fn destructure(self: Self) View {
            return switch (self.inner) {
                .some => |v| .{ .some = v },
                .none => .{ .none = {} },
            };
        }
    };
}

/// Result(T, E) — either a success value or an error.
///
/// ```
/// switch (result.destructure()) {
///     .ok  => |v| ...,
///     .err => |e| ...,
/// }
/// ```
pub fn Result(comptime T: type, comptime E: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        const Inner = union(enum) {
            ok: T,
            err: E,
        };

        pub const View = union(enum) {
            ok: T,
            err: E,
        };

        pub fn ok(value: T) Self {
            return .{ .inner = .{ .ok = value } };
        }

        pub fn err(error_value: E) Self {
            return .{ .inner = .{ .err = error_value } };
        }

        pub fn isOk(self: Self) bool {
            return self.inner == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self.inner == .err;
        }

        /// Unwrap or return a default (discards the error).
        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self.inner) {
                .ok => |v| v,
                .err => default,
            };
        }

        /// Transform the ok value.
        pub fn map(self: Self, f: anytype) Result(@TypeOf(f.call(self.inner.ok)), E) {
            return switch (self.inner) {
                .ok => |v| .{ .inner = .{ .ok = f.call(v) } },
                .err => |e| .{ .inner = .{ .err = e } },
            };
        }

        /// Transform the error value.
        pub fn mapErr(self: Self, f: anytype) Result(T, @TypeOf(f.call(self.inner.err))) {
            return switch (self.inner) {
                .ok => |v| .{ .inner = .{ .ok = v } },
                .err => |e| .{ .inner = .{ .err = f.call(e) } },
            };
        }

        /// Flat-map: chain an operation that may fail.
        pub fn bind(self: Self, f: anytype) @TypeOf(f.call(self.inner.ok)) {
            return switch (self.inner) {
                .ok => |v| f.call(v),
                .err => |e| @TypeOf(f.call(self.inner.ok)).err(e),
            };
        }

        /// Return a tagged union for exhaustive switch matching.
        pub fn destructure(self: Self) View {
            return switch (self.inner) {
                .ok => |v| .{ .ok = v },
                .err => |e| .{ .err = e },
            };
        }
    };
}

/// Convenience: build a Some value with type inference.
pub fn some(value: anytype) Option(@TypeOf(value)) {
    return Option(@TypeOf(value)).some(value);
}

/// Convenience: build a None value (type must be specified).
pub fn none(comptime T: type) Option(T) {
    return Option(T).none();
}

/// Convenience: build an Ok value with type inference.
pub fn ok(value: anytype) Result(@TypeOf(value), void) {
    return Result(@TypeOf(value), void).ok(value);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const vec_mod = @import("vector.zig");

test "Option: some and none" {
    const s = Option(i32).some(42);
    try testing.expect(s.isSome());
    try testing.expect(!s.isNone());

    const n = Option(i32).none();
    try testing.expect(n.isNone());
    try testing.expect(!n.isSome());
}

test "Option: destructure with switch" {
    const s = some(@as(i32, 7));
    switch (s.destructure()) {
        .some => |v| try testing.expectEqual(@as(i32, 7), v),
        .none => try testing.expect(false),
    }

    const n = none(i32);
    switch (n.destructure()) {
        .some => try testing.expect(false),
        .none => {},
    }
}

test "Option: unwrapOr" {
    try testing.expectEqual(@as(i32, 10), some(@as(i32, 10)).unwrapOr(0));
    try testing.expectEqual(@as(i32, 0), none(i32).unwrapOr(0));
}

test "Option: map" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * 2; }
    };

    const s = some(@as(i32, 5)).map(Double{});
    switch (s.destructure()) {
        .some => |v| try testing.expectEqual(@as(i32, 10), v),
        .none => try testing.expect(false),
    }

    const n = none(i32).map(Double{});
    switch (n.destructure()) {
        .some => try testing.expect(false),
        .none => {},
    }
}

test "Option: bind" {
    const SafeDiv = struct {
        pub fn call(_: @This(), x: i32) Option(i32) {
            if (x == 0) return none(i32);
            return some(@divTrunc(100, x));
        }
    };

    const s = some(@as(i32, 4)).bind(SafeDiv{});
    switch (s.destructure()) {
        .some => |v| try testing.expectEqual(@as(i32, 25), v),
        .none => try testing.expect(false),
    }

    // bind on none propagates
    const n = none(i32).bind(SafeDiv{});
    try testing.expect(n.isNone());

    // bind that returns none
    const z = some(@as(i32, 0)).bind(SafeDiv{});
    try testing.expect(z.isNone());
}

test "Option: chained map+bind" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * 2; }
    };
    const NonZero = struct {
        pub fn call(_: @This(), x: i32) Option(i32) {
            return if (x == 0) none(i32) else some(x);
        }
    };

    const result = some(@as(i32, 3))
        .map(Double{})      // 3 → 6
        .bind(NonZero{});   // 6 → some(6)

    switch (result.destructure()) {
        .some => |v| try testing.expectEqual(@as(i32, 6), v),
        .none => try testing.expect(false),
    }

    // Chain that fails
    const fail = some(@as(i32, 0))
        .map(Double{})      // 0 → 0
        .bind(NonZero{});   // 0 → none

    try testing.expect(fail.isNone());
}

test "Result: ok and err" {
    const o = Result(i32, []const u8).ok(42);
    try testing.expect(o.isOk());
    try testing.expect(!o.isErr());

    const e = Result(i32, []const u8).err("failed");
    try testing.expect(e.isErr());
    try testing.expect(!e.isOk());
}

test "Result: destructure" {
    const o = Result(i32, []const u8).ok(7);
    switch (o.destructure()) {
        .ok => |v| try testing.expectEqual(@as(i32, 7), v),
        .err => try testing.expect(false),
    }

    const e = Result(i32, []const u8).err("boom");
    switch (e.destructure()) {
        .ok => try testing.expect(false),
        .err => |msg| try testing.expectEqualStrings("boom", msg),
    }
}

test "Result: unwrapOr" {
    try testing.expectEqual(@as(i32, 5), Result(i32, []const u8).ok(5).unwrapOr(0));
    try testing.expectEqual(@as(i32, 0), Result(i32, []const u8).err("x").unwrapOr(0));
}

test "Result: map" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * 2; }
    };

    const o = Result(i32, []const u8).ok(5).map(Double{});
    switch (o.destructure()) {
        .ok => |v| try testing.expectEqual(@as(i32, 10), v),
        .err => try testing.expect(false),
    }
}

test "Result: map propagates err" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * 2; }
    };

    const e = Result(i32, []const u8).err("fail").map(Double{});
    switch (e.destructure()) {
        .ok => try testing.expect(false),
        .err => |msg| try testing.expectEqualStrings("fail", msg),
    }
}

test "Result: mapErr" {
    const Upper = struct {
        pub fn call(_: @This(), s: []const u8) []const u8 {
            _ = s;
            return "UPPER";
        }
    };

    const e = Result(i32, []const u8).err("fail").mapErr(Upper{});
    switch (e.destructure()) {
        .ok => try testing.expect(false),
        .err => |msg| try testing.expectEqualStrings("UPPER", msg),
    }
}

test "Result: bind" {
    const SafeDiv = struct {
        pub fn call(_: @This(), x: i32) Result(i32, []const u8) {
            if (x == 0) return Result(i32, []const u8).err("division by zero");
            return Result(i32, []const u8).ok(@divTrunc(100, x));
        }
    };

    const o = Result(i32, []const u8).ok(4).bind(SafeDiv{});
    switch (o.destructure()) {
        .ok => |v| try testing.expectEqual(@as(i32, 25), v),
        .err => try testing.expect(false),
    }

    const e = Result(i32, []const u8).ok(0).bind(SafeDiv{});
    try testing.expect(e.isErr());
}

test "Option: filterMap integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    const vec = try V.fromSlice(arena.allocator(), &.{ 1, 2, 3, 4, 5, 6 });
    defer vec.deinit();

    // Keep only evens, double them
    const EvenDouble = struct {
        pub fn call(_: @This(), x: i32) Option(i32) {
            if (@mod(x, 2) == 0) return some(x * 2);
            return none(i32);
        }
    };

    const result = try filterMapVec(i32, vec, EvenDouble{}, arena.allocator());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.len());
    try testing.expectEqual(@as(i32, 4), result.get(0).?);  // 2*2
    try testing.expectEqual(@as(i32, 8), result.get(1).?);  // 4*2
    try testing.expectEqual(@as(i32, 12), result.get(2).?); // 6*2
}

test "Option: filterMap on empty vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const V = vec_mod.Vector(i32);
    const vec = V.empty(arena.allocator());

    const Always = struct {
        pub fn call(_: @This(), x: i32) Option(i32) {
            return some(x);
        }
    };

    const result = try filterMapVec(i32, vec, Always{}, arena.allocator());
    defer result.deinit();
    try testing.expect(result.isEmpty());
}

// ── filterMap combinator ──

/// Map each element through a function returning Option(U), keeping
/// only the Some values. Single pass (no intermediate vector).
pub fn filterMapVec(
    comptime OutT: type,
    src: anytype,
    f: anytype,
    allocator: std.mem.Allocator,
) !vec_mod.Vector(OutT) {
    var result = vec_mod.Vector(OutT).empty(allocator);
    var it = src.iterator();
    while (it.next()) |elem| {
        const opt = f.call(elem);
        switch (opt.inner) {
            .some => |v| result = try result.pushBack(v),
            .none => {},
        }
    }
    return result;
}
