// JSON parser — raw Zig
// Parse subset: numbers, strings, arrays, objects, null, true, false.
const std = @import("std");

pub const Value = union(enum) {
    null_val: void,
    bool_val: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: []const Pair,
};
pub const Pair = struct { key: []const u8, value: Value };

const Ctx = struct {
    input: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
};

fn skipWS(ctx: *Ctx) void {
    while (ctx.pos < ctx.input.len and (ctx.input[ctx.pos] == ' ' or ctx.input[ctx.pos] == '\n' or ctx.input[ctx.pos] == '\r' or ctx.input[ctx.pos] == '\t')) {
        ctx.pos += 1;
    }
}

const ParseError = error{
    UnexpectedEnd, InvalidNull, InvalidBool, InvalidToken,
    UnterminatedString, InvalidNumber, UnclosedArray,
    UnclosedObject, ExpectedComma, ExpectedStringKey,
    ExpectedColon, TrailingCharacters, OutOfMemory, InvalidCharacter,
};

fn parseValue(ctx: *Ctx) ParseError!Value {
    skipWS(ctx);
    if (ctx.pos >= ctx.input.len) return error.UnexpectedEnd;
    return switch (ctx.input[ctx.pos]) {
        'n' => parseNull(ctx),
        't' => parseBool(ctx, true),
        'f' => parseBool(ctx, false),
        '"' => parseString(ctx),
        '[' => parseArray(ctx),
        '{' => parseObject(ctx),
        else => parseNumber(ctx),
    };
}

fn parseNull(ctx: *Ctx) ParseError!Value {
    if (ctx.pos + 4 > ctx.input.len or !std.mem.eql(u8, ctx.input[ctx.pos..ctx.pos+4], "null")) return error.InvalidNull;
    ctx.pos += 4;
    return .{ .null_val = {} };
}

fn parseBool(ctx: *Ctx, val: bool) ParseError!Value {
    const word = if (val) "true" else "false";
    if (ctx.pos + word.len > ctx.input.len or !std.mem.eql(u8, ctx.input[ctx.pos..ctx.pos+word.len], word)) return error.InvalidBool;
    ctx.pos += word.len;
    return .{ .bool_val = val };
}

fn parseString(ctx: *Ctx) ParseError!Value {
    ctx.pos += 1; // skip opening "
    const start = ctx.pos;
    while (ctx.pos < ctx.input.len and ctx.input[ctx.pos] != '"') ctx.pos += 1;
    if (ctx.pos >= ctx.input.len) return error.UnterminatedString;
    const s = ctx.input[start..ctx.pos];
    ctx.pos += 1; // skip closing "
    return .{ .string = s };
}

fn parseNumber(ctx: *Ctx) ParseError!Value {
    const start = ctx.pos;
    if (ctx.pos < ctx.input.len and ctx.input[ctx.pos] == '-') ctx.pos += 1;
    while (ctx.pos < ctx.input.len and std.ascii.isDigit(ctx.input[ctx.pos])) ctx.pos += 1;
    if (ctx.pos < ctx.input.len and ctx.input[ctx.pos] == '.') {
        ctx.pos += 1;
        while (ctx.pos < ctx.input.len and std.ascii.isDigit(ctx.input[ctx.pos])) ctx.pos += 1;
    }
    if (start == ctx.pos) return error.InvalidNumber;
    return .{ .number = try std.fmt.parseFloat(f64, ctx.input[start..ctx.pos]) };
}

fn parseArray(ctx: *Ctx) ParseError!Value {
    ctx.pos += 1; // skip [
    var items = try std.ArrayList(Value).initCapacity(ctx.allocator, 0);
    errdefer items.deinit(ctx.allocator);
    skipWS(ctx);
    if (ctx.pos < ctx.input.len and ctx.input[ctx.pos] == ']') { ctx.pos += 1; return .{ .array = try items.toOwnedSlice(ctx.allocator) }; }
    while (true) {
        try items.append(ctx.allocator, try parseValue(ctx));
        skipWS(ctx);
        if (ctx.pos >= ctx.input.len) return error.UnclosedArray;
        if (ctx.input[ctx.pos] == ']') { ctx.pos += 1; return .{ .array = try items.toOwnedSlice(ctx.allocator) }; }
        if (ctx.input[ctx.pos] != ',') return error.ExpectedComma;
        ctx.pos += 1;
    }
}

fn parseObject(ctx: *Ctx) ParseError!Value {
    ctx.pos += 1; // skip {
    var pairs = try std.ArrayList(Pair).initCapacity(ctx.allocator, 0);
    errdefer pairs.deinit(ctx.allocator);
    skipWS(ctx);
    if (ctx.pos < ctx.input.len and ctx.input[ctx.pos] == '}') { ctx.pos += 1; return .{ .object = try pairs.toOwnedSlice(ctx.allocator) }; }
    while (true) {
        skipWS(ctx);
        if (ctx.input[ctx.pos] != '"') return error.ExpectedStringKey;
        const key = (try parseString(ctx)).string;
        skipWS(ctx);
        if (ctx.pos >= ctx.input.len or ctx.input[ctx.pos] != ':') return error.ExpectedColon;
        ctx.pos += 1;
        try pairs.append(ctx.allocator, .{ .key = key, .value = try parseValue(ctx) });
        skipWS(ctx);
        if (ctx.pos >= ctx.input.len) return error.UnclosedObject;
        if (ctx.input[ctx.pos] == '}') { ctx.pos += 1; return .{ .object = try pairs.toOwnedSlice(ctx.allocator) }; }
        if (ctx.input[ctx.pos] != ',') return error.ExpectedComma;
        ctx.pos += 1;
    }
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    var ctx = Ctx{ .input = input, .allocator = allocator };
    const val = try parseValue(&ctx);
    skipWS(&ctx);
    if (ctx.pos != ctx.input.len) return error.TrailingCharacters;
    return val;
}
