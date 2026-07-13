const std = @import("std");
const list_mod = @import("list.zig");

/// Persistent queue using the two-list approach. O(1) amortized push
/// and pop. Structural sharing — unchanged parts are shared between
/// versions.
///
/// The queue maintains two lists: `front` (elements to pop from) and
/// `back` (elements pushed, stored in reverse order). When `front`
/// becomes empty, `back` is reversed into `front` — this is O(n) but
/// occurs only once per element, giving O(1) amortized.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const L = list_mod.List(T);

        allocator: std.mem.Allocator,
        front: L,
        back: L,

        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .front = L.empty(allocator),
                .back = L.empty(allocator),
            };
        }

        pub fn len(self: Self) usize {
            return self.front.len() + self.back.len();
        }

        pub fn isEmpty(self: Self) bool {
            return self.front.isEmpty() and self.back.isEmpty();
        }

        pub fn push(self: Self, value: T) !Self {
            return .{
                .allocator = self.allocator,
                .front = self.front,
                .back = try self.back.cons(value),
            };
        }

        pub fn pop(self: Self) !?struct { value: T, rest: Self } {
            if (self.front.isEmpty()) {
                // Reverse back into front
                var new_front = L.empty(self.allocator);
                var cur = self.back;
                while (cur.head()) |v| {
                    new_front = try new_front.cons(v);
                    cur = cur.tail().?;
                }
                if (new_front.isEmpty()) return null; // completely empty
                const head = new_front.head().?;
                return .{ .value = head, .rest = .{
                    .allocator = self.allocator,
                    .front = new_front.tail().?,
                    .back = L.empty(self.allocator),
                } };
            }
            const head = self.front.head().?;
            return .{ .value = head, .rest = .{
                .allocator = self.allocator,
                .front = self.front.tail().?,
                .back = self.back,
            } };
        }

        pub fn deinit(self: Self) void {
            self.front.deinit();
            self.back.deinit();
        }
    };
}

test "Queue: push and pop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Q = Queue(i32);
    var q = Q.empty(arena.allocator());
    defer q.deinit();

    q = try q.push(1);
    q = try q.push(2);
    q = try q.push(3);

    try std.testing.expectEqual(@as(usize, 3), q.len());

    const r1 = (try q.pop()).?;
    try std.testing.expectEqual(@as(i32, 1), r1.value);
    q = r1.rest;

    const r2 = (try q.pop()).?;
    try std.testing.expectEqual(@as(i32, 2), r2.value);
    q = r2.rest;

    const r3 = (try q.pop()).?;
    try std.testing.expectEqual(@as(i32, 3), r3.value);
    q = r3.rest;

    try std.testing.expect((try q.pop()) == null);
}

test "Queue: structural sharing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Q = Queue(i32);
    var q1 = Q.empty(arena.allocator());
    defer q1.deinit();
    const q2 = try q1.push(1);
    defer q2.deinit();

    try std.testing.expect(q1.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), q2.len());
}

test "Queue: interleaved push/pop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Q = Queue(i32);
    var q = Q.empty(arena.allocator());
    defer q.deinit();

    q = try q.push(1);
    q = try q.push(2);
    {
        const r = (try q.pop()).?;
        q = r.rest;
    }
    q = try q.push(3);
    q = try q.push(4);

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqual(@as(i32, 2), (try q.pop()).?.value);
    q = (try q.pop()).?.rest;
    try std.testing.expectEqual(@as(i32, 3), (try q.pop()).?.value);
    q = (try q.pop()).?.rest;
    try std.testing.expectEqual(@as(i32, 4), (try q.pop()).?.value);
}
