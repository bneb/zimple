const std = @import("std");

/// Compose two unary callables: `compose(f, g).call(x) = f.call(g.call(x))`.
/// Both must have a `.call(arg)` method. Returns a plain struct callable.
pub fn compose(f: anytype, g: anytype) Compose(@TypeOf(f), @TypeOf(g)) {
    return .{ .f = f, .g = g };
}

pub fn Compose(comptime F: type, comptime G: type) type {
    return struct {
        f: F,
        g: G,

        pub fn call(self: @This(), x: anytype) @TypeOf(self.f.call(self.g.call(x))) {
            return self.f.call(self.g.call(x));
        }
    };
}

/// Curry a binary callable: `curry(f, a).call(b) = f.call(a, b)`.
pub fn curry(f: anytype, first: anytype) Curry(@TypeOf(f), @TypeOf(first)) {
    return .{ .f = f, .first = first };
}

pub fn Curry(comptime F: type, comptime A: type) type {
    return struct {
        f: F,
        first: A,

        pub fn call(self: @This(), second: anytype) @TypeOf(self.f.call(self.first, second)) {
            return self.f.call(self.first, second);
        }
    };
}

/// Count calls to an inner callable. Useful for testing and debugging.
pub fn Counted(comptime F: type) type {
    return struct {
        inner: F,
        calls: usize = 0,

        pub fn call(self: *@This(), arg: anytype) @TypeOf(self.inner.call(arg)) {
            self.calls += 1;
            return self.inner.call(arg);
        }
    };
}

pub fn counted(inner: anytype) Counted(@TypeOf(inner)) {
    return .{ .inner = inner };
}

// ── wrap: turn a file-scope function into a callable instance ─────────────

/// Wrap a file-scope function with its environment, producing a callable.
///
/// Arity is detected automatically at comptime — binary functions (reduce,
/// fold) get a `.call(acc, x)` method; unary functions get `.call(x)`.
///
/// The function must take a concrete env type (not `anytype`) as its first
/// parameter, since the function pointer is stored at runtime.
///
/// ```
/// const DoublerEnv = struct { factor: i32 };
/// fn double(env: DoublerEnv, x: i32) i32 { return env.factor * x; }
/// const doubler = wrap(DoublerEnv{ .factor = 10 }, double);
/// doubler.call(5); // 50
///
/// const SumEnv = struct { mult: i32 };
/// fn scaleSum(env: SumEnv, acc: i32, x: i32) i32 { return acc + env.mult * x; }
/// const reducer = wrap(SumEnv{ .mult = 2 }, scaleSum);
/// reducer.call(0, 3); // 6
/// ```
pub fn wrap(env: anytype, comptime func: anytype) Wrapped(@TypeOf(env), @TypeOf(func)) {
    return .{ .env = env, .f = func };
}

fn Wrapped(comptime Env: type, comptime F: type) type {
    const info = @typeInfo(F).@"fn";
    const arity = info.params.len - 1; // minus env param

    if (arity == 1) {
        const In = info.params[1].type.?;
        const Out = info.return_type.?;
        return struct {
            env: Env,
            f: *const F,

            pub fn call(self: @This(), arg: In) Out {
                return self.f(self.env, arg);
            }
        };
    } else if (arity == 2) {
        const In1 = info.params[1].type.?;
        const In2 = info.params[2].type.?;
        const Out = info.return_type.?;
        return struct {
            env: Env,
            f: *const F,

            pub fn call(self: @This(), arg1: In1, arg2: In2) Out {
                return self.f(self.env, arg1, arg2);
            }
        };
    } else {
        @compileError("wrap: unsupported arity " ++ @tagName(@as(@TypeOf(arity), @intCast(arity))));
    }
}

/// Memoize a callable. Results cached by argument value in a linear list.
/// Best for small domains (≤ 50 unique args). Call `.deinit()` to free.
///
/// The key type `K` must be specified explicitly — it's the argument type
/// passed to `inner.call()`.
pub fn Memo(comptime F: type, comptime K: type) type {
    return struct {
        inner: F,
        entries: std.ArrayListUnmanaged(Entry) = .empty,

        const Entry = struct { key: K, value: V };

        /// Compute the return type from the method signature.
        const V = @TypeOf(@call(.auto, F.call, .{ @as(F, undefined), @as(K, undefined) }));

        pub fn call(self: *@This(), arg: K) V {
            for (self.entries.items) |*entry| {
                if (std.meta.eql(entry.key, arg)) return entry.value;
            }
            const result = self.inner.call(arg);
            self.entries.append(std.heap.page_allocator, .{ .key = arg, .value = result }) catch @panic("memo OOM");
            return result;
        }

        pub fn deinit(self: *@This()) void {
            self.entries.deinit(std.heap.page_allocator);
        }
    };
}

pub fn memo(inner: anytype, comptime K: type) Memo(@TypeOf(inner), K) {
    return .{ .inner = inner, .entries = .empty };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "compose: f(g(x))" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    const AddOne = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x + 1;
        }
    };

    const c = compose(Double{}, AddOne{});
    try testing.expectEqual(@as(i32, 4), c.call(1)); // (1+1)*2 = 4
    try testing.expectEqual(@as(i32, 22), c.call(10)); // (10+1)*2 = 22
}

test "compose: reverse order" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    const AddOne = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x + 1;
        }
    };

    const c = compose(AddOne{}, Double{});
    try testing.expectEqual(@as(i32, 3), c.call(1)); // (1*2)+1 = 3
}

test "curry: partial application" {
    const Add = struct {
        pub fn call(_: @This(), a: i32, b: i32) i32 {
            return a + b;
        }
    };

    const add5 = curry(Add{}, @as(i32, 5));
    try testing.expectEqual(@as(i32, 12), add5.call(7));
    try testing.expectEqual(@as(i32, 15), add5.call(10));
}

test "curry + compose: pipeline" {
    const Mul = struct {
        pub fn call(_: @This(), a: i32, b: i32) i32 {
            return a * b;
        }
    };
    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * x;
        }
    };

    const triple = curry(Mul{}, @as(i32, 3));
    const c = compose(Square{}, triple);
    try testing.expectEqual(@as(i32, 36), c.call(2)); // (3*2)^2 = 36
    try testing.expectEqual(@as(i32, 225), c.call(5)); // (3*5)^2 = 225
}

test "counted: tracks calls" {
    const Double = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * 2;
        }
    };
    var c = counted(Double{});
    try testing.expectEqual(@as(i32, 4), c.call(2));
    try testing.expectEqual(@as(i32, 6), c.call(3));
    try testing.expectEqual(@as(usize, 2), c.calls);
}

test "memo: caches repeated calls" {
    var raw_count: usize = 0;
    const Expensive = struct {
        counter: *usize,
        pub fn call(self: @This(), x: i32) i32 {
            self.counter.* += 1;
            return x * x;
        }
    };
    var m = memo(Expensive{ .counter = &raw_count }, i32);
    defer m.deinit();

    try testing.expectEqual(@as(i32, 25), m.call(5));
    try testing.expectEqual(@as(usize, 1), raw_count);

    try testing.expectEqual(@as(i32, 25), m.call(5));
    try testing.expectEqual(@as(usize, 1), raw_count); // cached

    try testing.expectEqual(@as(i32, 100), m.call(10));
    try testing.expectEqual(@as(usize, 2), raw_count); // new arg
}

test "memo: repeated calls with same arg" {
    var raw_count: usize = 0;
    const Len = struct {
        counter: *usize,
        pub fn call(self: @This(), s: []const u8) usize {
            self.counter.* += 1;
            return s.len;
        }
    };
    var m = memo(Len{ .counter = &raw_count }, []const u8);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 5), m.call("hello"));
    try testing.expectEqual(@as(usize, 1), raw_count);
    try testing.expectEqual(@as(usize, 5), m.call("hello"));
    try testing.expectEqual(@as(usize, 1), raw_count); // cached
}

// ── wrap tests ─────────────────────────────────────────────────────────────

const DoublerEnv = struct { factor: i32 };
fn doubleFn(env: DoublerEnv, x: i32) i32 {
    return env.factor * x;
}

const VoidEnv = struct {};
fn isEvenFn(_: VoidEnv, x: i32) bool {
    return @mod(x, 2) == 0;
}
fn squareFn(_: VoidEnv, x: i32) i32 {
    return x * x;
}

const SumEnv = struct { mult: i32 };
fn scaleSumFn(env: SumEnv, acc: i32, x: i32) i32 {
    return acc + env.mult * x;
}

test "wrap: unary callable" {
    const d = wrap(DoublerEnv{ .factor = 5 }, doubleFn);
    try testing.expectEqual(@as(i32, 25), d.call(5));
    try testing.expectEqual(@as(i32, 0), d.call(0));
}

test "wrap: zero-state callable" {
    const isEvenC = wrap(VoidEnv{}, isEvenFn);
    try testing.expectEqual(true, isEvenC.call(2));
    try testing.expectEqual(false, isEvenC.call(3));
}

test "wrap: composes with mapVec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec_mod = @import("vector.zig");
    const c = @import("combinators.zig");

    const V = vec_mod.Vector(i32);
    const vec = try V.fromSlice(arena.allocator(), &.{ 1, 2, 3, 4 });
    defer vec.deinit();

    const s = wrap(VoidEnv{}, squareFn);
    const mapped = try c.mapVec(i32, vec, s, arena.allocator());
    defer mapped.deinit();

    try testing.expectEqual(@as(i32, 1), mapped.get(0).?);
    try testing.expectEqual(@as(i32, 4), mapped.get(1).?);
    try testing.expectEqual(@as(i32, 9), mapped.get(2).?);
    try testing.expectEqual(@as(i32, 16), mapped.get(3).?);
}

test "wrap: binary callable (auto-detected)" {
    const r = wrap(SumEnv{ .mult = 10 }, scaleSumFn);
    try testing.expectEqual(@as(i32, 30), r.call(0, 3)); // 0 + 10*3
    try testing.expectEqual(@as(i32, 70), r.call(30, 4)); // 30 + 10*4
}

test "wrap: binary composes with reduceVec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vec_mod = @import("vector.zig");
    const c = @import("combinators.zig");

    const V = vec_mod.Vector(i32);
    const vec = try V.fromSlice(arena.allocator(), &.{ 1, 2, 3, 4 });
    defer vec.deinit();

    const r = wrap(SumEnv{ .mult = 1 }, scaleSumFn);
    try testing.expectEqual(@as(i32, 10), c.reduceVec(vec, r, @as(i32, 0)));
}
