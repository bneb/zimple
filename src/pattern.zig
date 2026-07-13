const std = @import("std");
const list_mod = @import("list.zig");
const vec_mod = @import("vector.zig");

/// Destructured view of a cons-list for use with Zig's native `switch`.
pub fn ListCons(comptime T: type) type {
    return union(enum) {
        empty: void,
        cons: struct { head: T, tail: list_mod.List(T) },
    };
}

/// Destructure a list into a matchable tagged union.
/// Usage:
///   switch (destructureList(list)) {
///     .empty => ...,
///     .cons => |c| { c.head; c.tail; },
///   }
pub fn destructureList(list: anytype) ListCons(@TypeOf(list.head().?)) {
    if (list.isEmpty()) return .{ .empty = {} };
    return .{ .cons = .{ .head = list.head().?, .tail = list.tail().? } };
}

/// Convenience: match a list against two comptime function bodies.
/// Both branches must return the same type R.
pub fn matchList(list: anytype, comptime ifEmpty: anytype, comptime ifCons: anytype) @TypeOf(ifCons(list.head().?, list.tail().?)) {
    if (list.isEmpty()) {
        return ifEmpty();
    } else {
        return ifCons(list.head().?, list.tail().?);
    }
}

/// Simplified match for two-variant tagged unions.
/// Pass the return type explicitly and two handler functions.
/// Pass the return type explicitly and two handlers.
pub fn match2(
    value: anytype,
    comptime ReturnT: type,
    comptime handler_a: anytype,
    comptime handler_b: anytype,
) ReturnT {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .@"union" => |u| {
            if (u.fields.len != 2) {
                @compileError("match2 requires a 2-variant tagged union, got " ++ @typeName(T));
            }
            switch (value) {
                @field(T, u.fields[0].name) => |payload| {
                    return handler_a(payload);
                },
                @field(T, u.fields[1].name) => |payload| {
                    return handler_b(payload);
                },
            }
        },
        else => @compileError("match2 requires a tagged union, got " ++ @typeName(T)),
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "destructureList on cons" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(30);
    list = try list.cons(20);
    list = try list.cons(10);
    defer list.deinit();

    const d = destructureList(list);
    switch (d) {
        .empty => try testing.expect(false),
        .cons => |c| {
            try testing.expectEqual(@as(i32, 10), c.head);
            try testing.expectEqual(@as(usize, 2), c.tail.len());
        },
    }
}

test "destructureList on empty" {
    const L = list_mod.List(i32);
    const list = L.empty(testing.allocator);

    const d = destructureList(list);
    switch (d) {
        .empty => try testing.expect(true),
        .cons => try testing.expect(false),
    }
}

test "matchList" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(30);
    list = try list.cons(20);
    list = try list.cons(10);
    defer list.deinit();

    const result = matchList(list,
        struct {
            fn f() i32 { return 0; }
        }.f,
        struct {
            fn f(head: i32, tail: L) i32 {
                _ = tail;
                return head;
            }
        }.f,
    );
    try testing.expectEqual(@as(i32, 10), result);
}

test "matchList on empty" {
    const L = list_mod.List(i32);
    const list = L.empty(testing.allocator);

    const result = matchList(list,
        struct {
            fn f() i32 { return 0; }
        }.f,
        struct {
            fn f(head: i32, tail: L) i32 {
                _ = head;
                _ = tail;
                return -1;
            }
        }.f,
    );
    try testing.expectEqual(@as(i32, 0), result);
}

test "destructureList — nested pattern matching" {
    const L = list_mod.List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(30);
    list = try list.cons(20);
    list = try list.cons(10);
    defer list.deinit();
    // [10, 20, 30]

    // Match on the outer list, then destructure the tail
    const d1 = destructureList(list);
    switch (d1) {
        .empty => try testing.expect(false),
        .cons => |c1| {
            try testing.expectEqual(@as(i32, 10), c1.head);
            const d2 = destructureList(c1.tail);
            switch (d2) {
                .empty => try testing.expect(false),
                .cons => |c2| {
                    try testing.expectEqual(@as(i32, 20), c2.head);
                },
            }
        },
    }
}

test "exhaustive match enforcement" {
    // This test verifies that match2 enforces a 2-variant union at comptime.
    const MyUnion = union(enum) {
        first: i32,
        second: []const u8,
    };
    const value: MyUnion = .{ .first = 42 };

    const result = match2(value, i32,
        struct {
            fn f(payload: i32) i32 { return payload * 2; }
        }.f,
        struct {
            fn f(payload: []const u8) i32 {
                _ = payload;
                return 0;
            }
        }.f,
    );
    try testing.expectEqual(@as(i32, 84), result);
}

test "match2 with second variant" {
    const MyUnion = union(enum) {
        first: i32,
        second: []const u8,
    };
    const value: MyUnion = .{ .second = "hello" };

    const result = match2(value, usize,
        struct {
            fn f(payload: i32) usize {
                _ = payload;
                return 0;
            }
        }.f,
        struct {
            fn f(payload: []const u8) usize { return payload.len; }
        }.f,
    );
    try testing.expectEqual(@as(usize, 5), result);
}
