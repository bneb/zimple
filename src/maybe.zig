// Option(T) and Result(T, E). Chainable map/bind/unwrapOr.
// Destructure with Zig native switch for exhaustive matching.
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

