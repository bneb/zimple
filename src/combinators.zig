const std = @import("std");
const list_mod = @import("list.zig");
const vec_mod = @import("vector.zig");

/// Apply a closure to each element of a cons-list, producing a new list.
pub fn mapList(
    comptime OutT: type,
    src: anytype,
    f: anytype,
    allocator: std.mem.Allocator,
) !list_mod.List(OutT) {
    var buf = std.ArrayListUnmanaged(OutT).initBuffer(&.{});
    defer buf.deinit(allocator);
    var it = src.iterator();
    while (it.next()) |elem| {
        try buf.append(allocator, f.call(elem));
    }
    return bufToList(OutT, buf.items, allocator);
}

/// Filter a cons-list with a predicate. Returns a list of the same type.
pub fn filterList(
    src: anytype,
    pred: anytype,
    allocator: std.mem.Allocator,
) !@TypeOf(src) {
    const T = @TypeOf(src.head().?);
    var buf = std.ArrayListUnmanaged(T).initBuffer(&.{});
    defer buf.deinit(allocator);
    var it = src.iterator();
    while (it.next()) |elem| {
        if (pred.call(elem)) try buf.append(allocator, elem);
    }
    return bufToList(@TypeOf(src.head().?), buf.items, allocator);
}

/// Fold-left over a cons-list with a binary closure.
pub fn reduceList(
    src: anytype,
    f: anytype,
    initial: anytype,
) @TypeOf(initial) {
    var acc = initial;
    var it = src.iterator();
    while (it.next()) |elem| acc = f.call(acc, elem);
    return acc;
}

/// Flat-map (bind) over a cons-list.
pub fn bindList(
    comptime OutT: type,
    src: anytype,
    f: anytype,
    allocator: std.mem.Allocator,
) !list_mod.List(OutT) {
    var buf = std.ArrayListUnmanaged(OutT).initBuffer(&.{});
    defer buf.deinit(allocator);
    var it = src.iterator();
    while (it.next()) |elem| {
        var inner = f.call(elem);
        defer inner.deinit();
        var inner_it = inner.iterator();
        while (inner_it.next()) |v| try buf.append(allocator, v);
    }
    return bufToList(OutT, buf.items, allocator);
}

fn bufToList(comptime T: type, items: []const T, allocator: std.mem.Allocator) !list_mod.List(T) {
    var result = list_mod.List(T).empty(allocator);
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        result = try result.cons(items[i]);
    }
    return result;
}

/// Apply a closure to each element of a persistent vector.
/// Uses a temporary buffer to batch-construct the result tree
/// (avoids per-element pushBack allocations).
pub fn mapVec(
    comptime OutT: type,
    src: anytype,
    f: anytype,
    allocator: std.mem.Allocator,
) !vec_mod.Vector(OutT) {
    const n = src.len();
    const buf = try allocator.alloc(OutT, n);
    defer allocator.free(buf);
    var it = src.iterator();
    var i: usize = 0;
    while (it.next()) |elem| : (i += 1) {
        buf[i] = f.call(elem);
    }
    return vec_mod.Vector(OutT).fromSlice(allocator, buf);
}

/// Filter a persistent vector with a predicate.
/// Two-pass: count matches, then batch-construct the result tree.
pub fn filterVec(
    src: anytype,
    pred: anytype,
    allocator: std.mem.Allocator,
) !@TypeOf(src) {
    const T = @TypeOf(src).Element;
    // First pass: count matches
    var count: usize = 0;
    var it1 = src.iterator();
    while (it1.next()) |elem| {
        if (pred.call(elem)) count += 1;
    }
    if (count == 0) return @TypeOf(src).empty(allocator);

    // Second pass: collect matches
    const buf = try allocator.alloc(T, count);
    defer allocator.free(buf);
    var it2 = src.iterator();
    var i: usize = 0;
    while (it2.next()) |elem| {
        if (pred.call(elem)) {
            buf[i] = elem;
            i += 1;
        }
    }
    return @TypeOf(src).fromSlice(allocator, buf);
}

/// Fold-left over a persistent vector with a binary closure.
pub fn reduceVec(
    src: anytype,
    f: anytype,
    initial: anytype,
) @TypeOf(initial) {
    var acc = initial;
    var i: usize = 0;
    while (i < src.len()) : (i += 1) acc = f.call(acc, src.get(i).?);
    return acc;
}

/// Flat-map (bind) over a persistent vector.
pub fn bindVec(
    comptime OutT: type,
    src: anytype,
    f: anytype,
    allocator: std.mem.Allocator,
) !vec_mod.Vector(OutT) {
    var result = vec_mod.Vector(OutT).empty(allocator);
    var it = src.iterator();
    while (it.next()) |elem| {
        var inner = f.call(elem);
        defer inner.deinit();
        var inner_it = inner.iterator();
        while (inner_it.next()) |inner_elem| {
            result = try result.pushBack(inner_elem);
        }
    }
    return result;
}
