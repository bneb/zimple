const std = @import("std");
const testing = std.testing;
const vector = @import("vector.zig");

const PV = vector.Vector(i32);
const PVOut = vector.Vector(i64);

fn scalarMapFn(val: i32) i64 {
    return @as(i64, val) * 2;
}

fn simdMapFn(vec: @Vector(4, i32)) @Vector(4, i64) {
    const v: @Vector(4, i64) = .{
        @as(i64, vec[0]),
        @as(i64, vec[1]),
        @as(i64, vec[2]),
        @as(i64, vec[3]),
    };
    const twos: @Vector(4, i64) = .{ 2, 2, 2, 2 };
    return v * twos;
}

fn scalarReduceFn(a: i64, b: i32) i64 {
    return a + @as(i64, b);
}

fn simdReduceFn(acc: @Vector(4, i64), vec: @Vector(4, i32)) @Vector(4, i64) {
    const v: @Vector(4, i64) = .{
        @as(i64, vec[0]),
        @as(i64, vec[1]),
        @as(i64, vec[2]),
        @as(i64, vec[3]),
    };
    return acc + v;
}

fn scalarMergeFn(a: i64, b: i64) i64 {
    return a + b;
}

test "simd: map parity with scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pv = PV.empty(alloc);
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        pv = try pv.pushBack(i);
    }
    const leaf = pv.root.?;

    const mapped = try PV.simdMapLeaf(i64, alloc, leaf, simdMapFn, scalarMapFn);
    
    i = 0;
    while (i < 32) : (i += 1) {
        try testing.expectEqual(@as(i64, i * 2), mapped.leaf.values[@intCast(i)]);
    }
}

test "simd: reduce parity with scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pv = PV.empty(alloc);
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        pv = try pv.pushBack(i);
    }
    const leaf = pv.root.?;

    const sum = PV.simdReduceLeaf(i64, leaf, simdReduceFn, scalarReduceFn, scalarMergeFn, 0);
    // sum(0..31) = 31 * 32 / 2 = 496
    try testing.expectEqual(@as(i64, 496), sum);
}

test "simd: partial bitmap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pv = PV.empty(alloc);
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        pv = try pv.pushBack(i);
    }
    const leaf = pv.root.?;

    const sum = PV.simdReduceLeaf(i64, leaf, simdReduceFn, scalarReduceFn, scalarMergeFn, 0);
    // sum(0..9) = 9 * 10 / 2 = 45
    try testing.expectEqual(@as(i64, 45), sum);
}

test "simd: identity transform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pv = PV.empty(alloc);
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        pv = try pv.pushBack(i);
    }
    const leaf = pv.root.?;

    const identitySimd = struct {
        fn f(v: @Vector(4, i32)) @Vector(4, i32) { return v; }
    }.f;
    const identityScalar = struct {
        fn f(v: i32) i32 { return v; }
    }.f;

    const mapped = try PV.simdMapLeaf(i32, alloc, leaf, identitySimd, identityScalar);
    
    i = 0;
    while (i < 32) : (i += 1) {
        try testing.expectEqual(i, mapped.leaf.values[@intCast(i)]);
    }
}
