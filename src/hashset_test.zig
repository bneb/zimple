const std = @import("std");
const hamt = @import("hamt.zig");
const hashset = @import("hashset.zig");
const testing = std.testing;

const H = hashset.HashSet(i32, hamt.autoHash(i32));

test "HashSet: empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = H.empty(arena.allocator());
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.len());
    try testing.expect(s.isEmpty());
}

test "HashSet: insert and contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = H.empty(arena.allocator());
    defer s.deinit();
    s = try s.insert(1);
    s = try s.insert(2);
    s = try s.insert(3);
    try testing.expectEqual(@as(usize, 3), s.len());
    try testing.expect(s.contains(1));
    try testing.expect(s.contains(2));
    try testing.expect(!s.contains(99));
}

test "HashSet: structural sharing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s1 = H.empty(arena.allocator());
    defer s1.deinit();
    s1 = try s1.insert(1);
    const s2 = try s1.insert(2);
    defer s2.deinit();
    try testing.expect(s1.contains(1));
    try testing.expect(!s1.contains(2));
    try testing.expect(s2.contains(1));
    try testing.expect(s2.contains(2));
}

test "HashSet: remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = H.empty(arena.allocator());
    defer s.deinit();
    s = try s.insert(1);
    s = try s.insert(2);
    const s2 = try s.remove(1);
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 1), s2.len());
    try testing.expect(!s2.contains(1));
    try testing.expect(s2.contains(2));
}

test "HashSet: fromSlice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try H.fromSlice(arena.allocator(), &.{ 1, 2, 3 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.len());
}

test "HashSet: union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s1 = H.empty(arena.allocator());
    defer s1.deinit(); s1 = try s1.insert(1); s1 = try s1.insert(2);
    var s2 = H.empty(arena.allocator());
    defer s2.deinit(); s2 = try s2.insert(2); s2 = try s2.insert(3);
    const su = try s1.unionWith(s2);
    defer su.deinit();
    try testing.expectEqual(@as(usize, 3), su.len());
    try testing.expect(su.contains(1));
    try testing.expect(su.contains(2));
    try testing.expect(su.contains(3));
}

test "HashSet: intersect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s1 = H.empty(arena.allocator());
    defer s1.deinit(); s1 = try s1.insert(1); s1 = try s1.insert(2);
    var s2 = H.empty(arena.allocator());
    defer s2.deinit(); s2 = try s2.insert(2); s2 = try s2.insert(3);
    const si = try s1.intersect(s2);
    defer si.deinit();
    try testing.expectEqual(@as(usize, 1), si.len());
    try testing.expect(si.contains(2));
}

test "HashSet: iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = H.empty(arena.allocator());
    defer s.deinit();
    s = try s.insert(1); s = try s.insert(2); s = try s.insert(3);
    var it = s.iterator();
    var count: usize = 0;
    while (it.next()) |e| { count += 1; _ = e.key; }
    try testing.expectEqual(@as(usize, 3), count);
}
