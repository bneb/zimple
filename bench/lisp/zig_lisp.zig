// Zig-native Lisp interpreter — uses raw tagged unions, manual alloc/free,
// function pointers for builtins, and switch-based eval dispatch.
//
// Run: zig run bench/lisp/zig_lisp.zig -- test-name
// Benchmark: zig run -OReleaseFast bench/lisp/harness.zig

const std = @import("std");

pub const Expr = union(enum) {
    nil: void,
    number: i64,
    symbol: []const u8,
    builtin: *const fn (*EvalCtx, []const Expr) anyerror!Expr,
    lambda: struct { params: [][]const u8, body: *const Expr, captured: *anyopaque },
    list: List,

    pub const List = struct {
        items: []const Expr,
    };
};

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

// ── Parser ──

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

    s = s[1..]; // skip '('
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
    errdefer ctx.allocator.free(result);
    for (items, 0..) |item, i| {
        result[i] = try eval(item, ctx);
    }
    return result;
}

fn eval(expr: Expr, ctx: *EvalCtx) anyerror!Expr {
    switch (expr) {
        .number, .builtin, .lambda, .nil => return expr,
        .symbol => |name| {
            return ctx.env.lookup(name) orelse {
                std.debug.print("undefined: {s}\n", .{name});
                return error.UndefinedSymbol;
            };
        },
        .list => |l| {
            if (l.items.len == 0) return expr;
            // Check for special forms before evaluating the first element
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
                .builtin => |b| {
                    const args = try evalList(l.items[1..], ctx);
                    defer ctx.allocator.free(args);
                    return b(ctx, args);
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
    // Install a dummy binding first so recursive references resolve.
    const env_node = try ctx.allocator.create(Env);
    env_node.* = makeEnv(ctx.env, name, .{ .nil = {} });
    ctx.env = env_node;
    // Now evaluate the value in the extended env (enables recursion).
    const val = try eval(args[1], ctx);
    ctx.env.value = val;
    return val;
}

fn evalQuote(args: []const Expr) Expr {
    if (args.len == 0) return .{ .nil = {} };
    return args[0];
}

// ── Builtins ──

fn builtinAdd(ctx: *EvalCtx, args: []const Expr) !Expr {
    var sum: i64 = 0;
    for (args) |a| sum += a.number;
    _ = ctx;
    return .{ .number = sum };
}

fn builtinMul(ctx: *EvalCtx, args: []const Expr) !Expr {
    var prod: i64 = 1;
    for (args) |a| prod *= a.number;
    _ = ctx;
    return .{ .number = prod };
}

fn builtinSub(ctx: *EvalCtx, args: []const Expr) !Expr {
    _ = ctx;
    if (args.len == 1) return .{ .number = -args[0].number };
    return .{ .number = args[0].number - args[1].number };
}

fn builtinEq(ctx: *EvalCtx, args: []const Expr) !Expr {
    _ = ctx;
    if (args.len < 2) return error.ArityMismatch;
    return if (args[0].number == args[1].number) Expr{ .number = 1 } else Expr{ .nil = {} };
}

fn builtinLt(ctx: *EvalCtx, args: []const Expr) !Expr {
    _ = ctx;
    if (args.len < 2) return error.ArityMismatch;
    return if (args[0].number < args[1].number) Expr{ .number = 1 } else Expr{ .nil = {} };
}

fn builtinCar(ctx: *EvalCtx, args: []const Expr) !Expr {
    _ = ctx;
    if (args.len < 1) return error.ArityMismatch;
    return switch (args[0]) {
        .list => |l| if (l.items.len > 0) l.items[0] else Expr{ .nil = {} },
        else => error.TypeError,
    };
}

fn builtinCdr(ctx: *EvalCtx, args: []const Expr) !Expr {
    _ = ctx;
    if (args.len < 1) return error.ArityMismatch;
    return switch (args[0]) {
        .list => |l| if (l.items.len > 1) Expr{ .list = .{ .items = l.items[1..] } } else Expr{ .nil = {} },
        else => error.TypeError,
    };
}

fn builtinCons(ctx: *EvalCtx, args: []const Expr) !Expr {
    if (args.len < 2) return error.ArityMismatch;
    const rest = switch (args[1]) {
        .list => |l| l.items,
        .nil => &[_]Expr{},
        else => |e| cons_blk: {
            const s = try ctx.allocator.alloc(Expr, 1);
            s[0] = e;
            break :cons_blk s;
        },
    };
    var all = try ctx.allocator.alloc(Expr, 1 + rest.len);
    all[0] = args[0];
    @memcpy(all[1..], rest);
    return .{ .list = .{ .items = all } };
}

// ── Test runner ──

pub fn main() !void {
    std.debug.print("=== Zig Lisp Test Suite ===\n\n", .{});
    var passed: usize = 0;
    var failed: usize = 0;

    for (testPrograms) |prog| {
        const result = run(std.heap.page_allocator, prog.source) catch |err| {
            std.debug.print("  {s}: ERROR {any}\n", .{ prog.name, err });
            failed += 1;
            continue;
        };
        if (result == prog.expected) {
            std.debug.print("  {s}: PASS ({d})\n", .{ prog.name, result });
            passed += 1;
        } else {
            std.debug.print("  {s}: FAIL (got {d}, expected {d})\n", .{ prog.name, result, prog.expected });
            failed += 1;
        }
    }
    std.debug.print("\n  {d}/{d} passed\n", .{ passed, passed + failed });
}

// ── Global env ──

fn makeGlobalEnv(allocator: std.mem.Allocator) !*Env {
    var env = try allocator.create(Env);
    env.* = makeEnv(null, "+", .{ .builtin = builtinAdd });
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "*", .{ .builtin = builtinMul });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "-", .{ .builtin = builtinSub });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "=", .{ .builtin = builtinEq });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "<", .{ .builtin = builtinLt });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "car", .{ .builtin = builtinCar });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "cdr", .{ .builtin = builtinCdr });
        break :blk n;
    };
    env = blk: {
        const n = try allocator.create(Env);
        n.* = makeEnv(env, "cons", .{ .builtin = builtinCons });
        break :blk n;
    };
    return env;
}

// ── Runner ──

pub fn run(allocator: std.mem.Allocator, source: []const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const env = try makeGlobalEnv(aa);
    var ctx: EvalCtx = .{ .allocator = aa, .env = env };

    // Evaluate all top-level expressions in sequence, return the last result.
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

// ── Test programs ──

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
