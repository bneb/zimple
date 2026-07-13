// Zimple-based Lisp interpreter — same semantics as zig_lisp.zig,
// but uses Zimple.Closure for builtins, Zimple.List for s-expressions,
// pattern matching for eval dispatch, and arena for memory management.
//
// Compare with zig_lisp.zig line-for-line to see the differences.

const std = @import("std");
const zimple = @import("zimple");

pub const Expr = union(enum) {
    nil: void,
    number: i64,
    symbol: []const u8,
    // Zimple: builtins are typed closures, not raw function pointers
    builtin: zimple.closure.Closure(BuiltinEnv, []const Expr, Expr),
    lambda: struct { params: [][]const u8, body: *const Expr, captured: *anyopaque },
    list: struct { items: []const Expr },
};

const BuiltinEnv = struct { ctx: *EvalCtx };

const EvalCtx = struct {
    allocator: std.mem.Allocator,
    env: *Env,
};

const Env = struct {
    parent: ?*Env,
    name: []const u8,
    value: Expr,

    fn lookup(e: *Env, name: []const u8) ?Expr {
        var cur: ?*Env = e;
        while (cur) |c| : (cur = c.parent) {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }
};

fn makeEnv(parent: ?*Env, name: []const u8, value: Expr) Env {
    return .{ .parent = parent, .name = name, .value = value };
}

// ── Parser (identical to zig_lisp.zig) ──

fn skipWS(input: []const u8) []const u8 {
    var s = input;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\n' or s[0] == '\t' or s[0] == '\r')) s = s[1..];
    return s;
}

const ParseResult = struct { e: Expr, rest: []const u8 };

fn parseAtom(input: []const u8) anyerror!ParseResult {
    const s = skipWS(input);
    if (s.len == 0) return error.UnexpectedEnd;
    if ((s[0] >= '0' and s[0] <= '9') or (s[0] == '-' and s.len > 1 and s[1] >= '0' and s[1] <= '9')) {
        var end: usize = if (s[0] == '-') @as(usize, 2) else 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
        return .{ .e = .{ .number = try std.fmt.parseInt(i64, s[0..end], 10) }, .rest = s[end..] };
    }
    if (std.ascii.isAlphabetic(s[0]) or s[0] == '+' or s[0] == '*' or s[0] == '/' or
        s[0] == '=' or s[0] == '<' or s[0] == '>' or s[0] == '?' or s[0] == '-' or s[0] == '!')
    {
        var end: usize = 1;
        while (end < s.len and !(s[end] == ' ' or s[end] == '\n' or s[end] == '\t' or
            s[end] == '\r' or s[end] == '(' or s[end] == ')')) end += 1;
        return .{ .e = .{ .symbol = s[0..end] }, .rest = s[end..] };
    }
    return error.InvalidToken;
}

fn parse(input: []const u8, allocator: std.mem.Allocator) anyerror!ParseResult {
    var s = skipWS(input);
    if (s.len == 0 or s[0] != '(') return parseAtom(s);
    s = s[1..];
    s = skipWS(s);
    if (s.len > 0 and s[0] == ')') return .{ .e = .{ .nil = {} }, .rest = s[1..] };

    var items: std.ArrayList(Expr) = .empty;
    errdefer items.deinit(allocator);
    while (true) {
        s = skipWS(s);
        if (s.len == 0) return error.UnclosedParen;
        if (s[0] == ')') {
            const slice = try items.toOwnedSlice(allocator);
            return .{ .e = .{ .list = .{ .items = slice } }, .rest = s[1..] };
        }
        const parsed = try parse(s, allocator);
        try items.append(allocator, parsed.e);
        s = parsed.rest;
    }
}

// ── Eval ──

fn evalList(items: []const Expr, ctx: *EvalCtx) ![]const Expr {
    var result = try ctx.allocator.alloc(Expr, items.len);
    for (items, 0..) |item, i| {
        result[i] = try eval(item, ctx);
    }
    return result;
}

fn eval(expr: Expr, ctx: *EvalCtx) anyerror!Expr {
    switch (expr) {
        .number, .builtin, .lambda, .nil => return expr,
        .symbol => |name| {
            return ctx.env.lookup(name) orelse error.UndefinedSymbol;
        },
        .list => |l| {
            if (l.items.len == 0) return expr;
            // Zimple: could use destructureList here for the eval, but
            // since we use raw []const Expr arrays for list storage,
            // the dispatch is identical to the Zig version.
            if (l.items[0] == .symbol) {
                const name = l.items[0].symbol;
                if (std.mem.eql(u8, name, "if")) return evalIf(l.items[1..], ctx);
                if (std.mem.eql(u8, name, "lambda")) return evalLambda(l.items[1..], ctx);
                if (std.mem.eql(u8, name, "let")) return evalLet(l.items[1..], ctx);
                if (std.mem.eql(u8, name, "define")) return evalDefine(l.items[1..], ctx);
                if (std.mem.eql(u8, name, "quote")) return evalQuote(l.items[1..]);
            }
            const first = try eval(l.items[0], ctx);
            switch (first) {
                // Zimple: builtins are invoked via .call(), not direct function call
                .builtin => |b| {
                    const args = try evalList(l.items[1..], ctx);
                    defer ctx.allocator.free(args);
                    return b.call(args);
                },
                .lambda => |lam| {
                    const args = try evalList(l.items[1..], ctx);
                    defer ctx.allocator.free(args);
                    if (args.len != lam.params.len) return error.ArityMismatch;
                    const captured_env: *Env = @ptrCast(@alignCast(lam.captured));
                    var new_env = captured_env;
                    for (lam.params, args) |param, arg| {
                        const env_node = try ctx.allocator.create(Env);
                        env_node.* = makeEnv(new_env, param, arg);
                        new_env = env_node;
                    }
                    var new_ctx: EvalCtx = .{ .allocator = ctx.allocator, .env = new_env };
                    return eval(lam.body.*, &new_ctx);
                },
                else => return error.NotCallable,
            }
        },
    }
}

fn evalIf(args: []const Expr, ctx: *EvalCtx) !Expr {
    if (args.len < 2) return error.MissingArgs;
    const cond = try eval(args[0], ctx);
    if (cond == .nil) {
        return if (args.len > 2) eval(args[2], ctx) else Expr{ .nil = {} };
    } else {
        return eval(args[1], ctx);
    }
}

fn evalLambda(args: []const Expr, ctx: *EvalCtx) !Expr {
    if (args.len < 2) return error.MissingArgs;
    const params: [][]const u8 = switch (args[0]) {
        .list => |l| params_blk: {
            var names = try ctx.allocator.alloc([]const u8, l.items.len);
            for (l.items, 0..) |item, i| {
                names[i] = switch (item) {
                    .symbol => |s| s,
                    else => return error.InvalidParam,
                };
            }
            break :params_blk names;
        },
        else => return error.InvalidParams,
    };
    const body_ptr = try ctx.allocator.create(Expr);
    body_ptr.* = args[1];
    return .{ .lambda = .{ .params = params, .body = body_ptr, .captured = @ptrCast(ctx.env) } };
}

fn evalLet(args: []const Expr, ctx: *EvalCtx) !Expr {
    if (args.len < 2) return error.MissingArgs;
    const bindings = switch (args[0]) {
        .list => |l| l,
        else => return error.MalformedLet,
    };
    var new_env = ctx.env;
    for (bindings.items) |binding| {
        const pair = switch (binding) {
            .list => |l| l,
            else => return error.MalformedBinding,
        };
        if (pair.items.len != 2) return error.MalformedBinding;
        const name = switch (pair.items[0]) {
            .symbol => |s| s,
            else => return error.BindingMustBeSymbol,
        };
        const val = try eval(pair.items[1], ctx);
        const env_node = try ctx.allocator.create(Env);
        env_node.* = makeEnv(new_env, name, val);
        new_env = env_node;
    }
    var new_ctx: EvalCtx = .{ .allocator = ctx.allocator, .env = new_env };
    return eval(args[1], &new_ctx);
}

fn evalDefine(args: []const Expr, ctx: *EvalCtx) !Expr {
    if (args.len < 2) return error.MissingArgs;
    const name = switch (args[0]) {
        .symbol => |s| s,
        else => return error.DefineNeedsSymbol,
    };
    const env_node = try ctx.allocator.create(Env);
    env_node.* = makeEnv(ctx.env, name, .{ .nil = {} });
    ctx.env = env_node;
    const val = try eval(args[1], ctx);
    ctx.env.value = val;
    return val;
}

fn evalQuote(args: []const Expr) Expr {
    if (args.len == 0) return .{ .nil = {} };
    return args[0];
}

// ── Builtins (Zimple: closures, not raw fn pointers) ──

fn builtinAdd(env: BuiltinEnv, args: []const Expr) Expr {
    var sum: i64 = 0;
    for (args) |a| sum += a.number;
    _ = env;
    return .{ .number = sum };
}

fn builtinMul(env: BuiltinEnv, args: []const Expr) Expr {
    var prod: i64 = 1;
    for (args) |a| prod *= a.number;
    _ = env;
    return .{ .number = prod };
}

fn builtinSub(env: BuiltinEnv, args: []const Expr) Expr {
    _ = env;
    if (args.len == 1) return .{ .number = -args[0].number };
    return .{ .number = args[0].number - args[1].number };
}

fn builtinEq(env: BuiltinEnv, args: []const Expr) Expr {
    _ = env;
    if (args.len < 2) return .{ .nil = {} };
    return if (args[0].number == args[1].number) Expr{ .number = 1 } else Expr{ .nil = {} };
}

fn builtinLt(env: BuiltinEnv, args: []const Expr) Expr {
    _ = env;
    if (args.len < 2) return .{ .nil = {} };
    return if (args[0].number < args[1].number) Expr{ .number = 1 } else Expr{ .nil = {} };
}

fn builtinCar(env: BuiltinEnv, args: []const Expr) Expr {
    _ = env;
    if (args.len < 1) return .{ .nil = {} };
    return switch (args[0]) {
        .list => |l| if (l.items.len > 0) l.items[0] else Expr{ .nil = {} },
        else => Expr{ .nil = {} },
    };
}

fn builtinCdr(env: BuiltinEnv, args: []const Expr) Expr {
    _ = env;
    if (args.len < 1) return .{ .nil = {} };
    return switch (args[0]) {
        .list => |l| if (l.items.len > 1) Expr{ .list = .{ .items = l.items[1..] } } else Expr{ .nil = {} },
        else => Expr{ .nil = {} },
    };
}

fn builtinCons(env: BuiltinEnv, args: []const Expr) Expr {
    if (args.len < 2) return .{ .nil = {} };
    const rest = switch (args[1]) {
        .list => |l| l.items,
        .nil => &[_]Expr{},
        else => |e| zl_cons_blk: {
            const s = env.ctx.allocator.alloc(Expr, 1) catch return .{ .nil = {} };
            s[0] = e;
            break :zl_cons_blk s;
        },
    };
    const all = env.ctx.allocator.alloc(Expr, 1 + rest.len) catch return .{ .nil = {} };
    all[0] = args[0];
    @memcpy(all[1..], rest);
    return .{ .list = .{ .items = all } };
}

// ── Global env (Zimple: closures, not raw fn ptrs) ──

fn makeGlobalEnv(allocator: std.mem.Allocator) !*Env {
    var env = try allocator.create(Env);
    env.* = makeEnv(null, "+", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinAdd) });
    const plus = env;
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "*", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinMul) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "-", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinSub) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "=", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinEq) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "<", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinLt) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "car", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinCar) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "cdr", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinCdr) });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "cons", .{ .builtin = zimple.closure.makeClosure(BuiltinEnv{ .ctx = undefined }, builtinCons) });
        break :blk n;
    };
    _ = plus;
    return env;
}

// ── Runner ──

pub fn run(allocator: std.mem.Allocator, source: []const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env = try makeGlobalEnv(aa);
    var ctx: EvalCtx = .{ .allocator = aa, .env = env };

    // Fix up the ctx pointers in builtin closures now that ctx is initialized
    // (they were initialized with undefined above)
    {
        var cur: ?*Env = env;
        while (cur) |c| : (cur = c.parent) {
            if (c.value == .builtin) {
                c.value.builtin.env.ctx = &ctx;
            }
        }
    }

    var rest = source;
    var last_result: Expr = .{ .nil = {} };
    while (true) {
        rest = skipWS(rest);
        if (rest.len == 0) break;
        const parsed = try parse(rest, aa);
        last_result = try eval(parsed.e, &ctx);
        rest = parsed.rest;
    }

    return switch (last_result) {
        .number => |n| n,
        .nil => 0,
        else => -1,
    };
}

// ── Test programs (same as zig_lisp.zig) ──

pub const TestProgram = struct { name: []const u8, source: []const u8, expected: i64 };

pub const testPrograms = [_]TestProgram{
    .{ .name = "fib-20", .source =
    \\ (define fib (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))
    \\ (fib 20)
    , .expected = 6765 },
    .{ .name = "ack-3-3", .source =
    \\ (define ack (lambda (m n)
    \\   (if (= m 0) (+ n 1)
    \\     (if (= n 0) (ack (- m 1) 1)
    \\       (ack (- m 1) (ack m (- n 1)))))))
    \\ (ack 3 3)
    , .expected = 61 },
    .{ .name = "sum-range", .source =
    \\ (define fold (lambda (f acc lst)
    \\   (if lst (fold f (f acc (car lst)) (cdr lst)) acc)))
    \\ (define range (lambda (lo hi)
    \\   (if (< lo hi) (cons lo (range (+ lo 1) hi)) (quote ()))))
    \\ (fold + 0 (range 0 100))
    , .expected = 4950 },
    .{ .name = "map-square", .source =
    \\ (define fold (lambda (f acc lst)
    \\   (if lst (fold f (f acc (car lst)) (cdr lst)) acc)))
    \\ (define map (lambda (f lst)
    \\   (if lst (cons (f (car lst)) (map f (cdr lst))) (quote ()))))
    \\ (define range (lambda (lo hi)
    \\   (if (< lo hi) (cons lo (range (+ lo 1) hi)) (quote ()))))
    \\ (define square (lambda (x) (* x x)))
    \\ (fold + 0 (map square (range 0 50)))
    , .expected = 40425 },
    .{ .name = "let-scope", .source = "(let ((x 10) (y 20)) (+ x y))", .expected = 30 },
    .{ .name = "lambda-capture", .source =
    \\ (define make-adder (lambda (x) (lambda (y) (+ x y))))
    \\ (let ((add5 (make-adder 5)))
    \\   (add5 10))
    , .expected = 15 },
};
