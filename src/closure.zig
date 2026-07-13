const std = @import("std");

/// Typed unary closure — a function pointer paired with its captured
/// environment, both stored by value.  No heap allocation for captures.
///
/// `Env` is the captured state.  `In` / `Out` are the argument and return
/// types.  The function convention is `fn (env: Env, arg: In) Out`.
///
/// Prefer a plain struct with a `.call()` method for inline logic.  Use
/// `Closure` when you need a concrete, nameable type (unions, struct
/// fields, heterogeneous storage).
pub fn Closure(comptime Env: type, comptime In: type, comptime Out: type) type {
    return struct {
        env: Env,
        invoke_fn: *const fn (env: Env, arg: In) Out,

        const Self = @This();

        pub fn call(self: Self, arg: In) Out {
            return self.invoke_fn(self.env, arg);
        }
    };
}

/// Typed binary closure for two-argument functions (reduce, fold, etc.).
pub fn Closure2(comptime Env: type, comptime In1: type, comptime In2: type, comptime Out: type) type {
    return struct {
        env: Env,
        invoke_fn: *const fn (env: Env, arg1: In1, arg2: In2) Out,

        const Self = @This();

        pub fn call(self: Self, arg1: In1, arg2: In2) Out {
            return self.invoke_fn(self.env, arg1, arg2);
        }
    };
}

/// Build a unary closure.  In and Out are inferred from the function
/// signature — no need to spell them out.
///
/// `func` must match `fn (env: @TypeOf(env), arg: In) Out`.
pub fn makeClosure(env: anytype, comptime func: anytype) Closure(
    @TypeOf(env),
    InferIn(@TypeOf(func)),
    InferOut(@TypeOf(func)),
) {
    return .{ .env = env, .invoke_fn = func };
}

/// Build a binary closure.  In1, In2, and Out are inferred.
pub fn makeClosure2(env: anytype, comptime func: anytype) Closure2(
    @TypeOf(env),
    InferIn1_2(@TypeOf(func)),
    InferIn2_2(@TypeOf(func)),
    InferOut(@TypeOf(func)),
) {
    return .{ .env = env, .invoke_fn = func };
}

// ── Type inference helpers ──────────────────────────────────────────────────

fn InferIn(comptime Fn: type) type {
    return @typeInfo(Fn).@"fn".params[1].type.?;
}

fn InferOut(comptime Fn: type) type {
    return @typeInfo(Fn).@"fn".return_type.?;
}

fn InferIn1_2(comptime Fn: type) type {
    return @typeInfo(Fn).@"fn".params[1].type.?;
}

fn InferIn2_2(comptime Fn: type) type {
    return @typeInfo(Fn).@"fn".params[2].type.?;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "capture primitive" {
    const state = .{ .multiplier = 5 };
    const logic = struct {
        fn apply(env: @TypeOf(state), x: i32) i32 {
            return env.multiplier * x;
        }
    }.apply;

    const c = makeClosure(state, logic);
    try testing.expectEqual(@as(i32, 50), c.call(10));
}

test "capture struct with multiple fields" {
    const state = .{ .mult = 3, .offset = 2 };
    const logic = struct {
        fn apply(env: @TypeOf(state), x: i32) i32 {
            return env.mult * x + env.offset;
        }
    }.apply;

    const c = makeClosure(state, logic);
    try testing.expectEqual(@as(i32, 11), c.call(3));
    try testing.expectEqual(@as(i32, 17), c.call(5));
}

test "zero-overhead — verify closure size" {
    const state = .{ .a = @as(i32, 1), .b = @as(i32, 2) };
    const logic = struct {
        fn apply(env: @TypeOf(state), x: i32) i32 {
            return env.a + env.b + x;
        }
    }.apply;
    const c = makeClosure(state, logic);
    try testing.expectEqual(
        @sizeOf(@TypeOf(state)) + @sizeOf(*const fn (@TypeOf(state), i32) i32),
        @sizeOf(@TypeOf(c)),
    );
}

test "composition — closure captures another closure" {
    const inner_state = .{ .factor = 2 };
    const inner_logic = struct {
        fn apply(env: @TypeOf(inner_state), x: i32) i32 {
            return env.factor * x;
        }
    }.apply;
    const double = makeClosure(inner_state, inner_logic);

    const outer_state = .{ .inner = double };
    const outer_logic = struct {
        fn apply(env: @TypeOf(outer_state), x: i32) i32 {
            return env.inner.call(x) + 1;
        }
    }.apply;
    const composed = makeClosure(outer_state, outer_logic);

    try testing.expectEqual(@as(i32, 15), composed.call(7)); // (2*7)+1
}

test "Closure2 — binary closure for reduce" {
    const state = .{ .mult = 10 };
    const logic = struct {
        fn apply(env: @TypeOf(state), acc: i32, x: i32) i32 {
            return acc + env.mult * x;
        }
    }.apply;

    const c = makeClosure2(state, logic);
    const r1 = c.call(0, 3);
    const r2 = c.call(r1, 4);
    try testing.expectEqual(@as(i32, 30), r1);
    try testing.expectEqual(@as(i32, 70), r2);
}

test "Closure2 size verification" {
    const state = .{ .scale = @as(f64, 1.5) };
    const logic = struct {
        fn apply(env: @TypeOf(state), a: f64, b: f64) f64 {
            return env.scale * (a + b);
        }
    }.apply;
    const c = makeClosure2(state, logic);
    try testing.expectEqual(
        @sizeOf(@TypeOf(state)) + @sizeOf(*const fn (@TypeOf(state), f64, f64) f64),
        @sizeOf(@TypeOf(c)),
    );
}

test "makeClosure with named function" {
    const state = .{ .prefix = "Hello, " };
    const greet = struct {
        fn apply(env: @TypeOf(state), name: []const u8) []const u8 {
            _ = name;
            return env.prefix;
        }
    }.apply;

    const c = makeClosure(state, greet);
    try testing.expectEqualStrings("Hello, ", c.call("World"));
}
