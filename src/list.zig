const std = @import("std");

/// A persistent, immutable singly-linked list with structural sharing.
/// `cons` allocates exactly one new node; the tail is shared, not copied.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Element = T;

        pub const Node = union(enum) {
            nil: void,
            cons: struct {
                head: T,
                tail: *const Node,
            },

            pub fn format(self: Node, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (self) {
                    .nil => try writer.writeAll("nil"),
                    .cons => |c| try writer.print("({any} :: ...)", .{c.head}),
                }
            }
        };

        /// Sentinel nil node — one per List(T), allocated at comptime.
        /// All empty lists and list tails terminate here.
        const nil_sentinel: Node = .nil;

        allocator: std.mem.Allocator,
        node: *const Node,

        /// Create an empty list. Uses the static nil sentinel.
        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .node = &nil_sentinel };
        }

        /// Prepend an element. Allocates one new cons node.
        /// The existing list (self) is unchanged — structural sharing.
        pub fn cons(self: Self, value: T) !Self {
            const new_node = try self.allocator.create(Node);
            new_node.* = .{ .cons = .{ .head = value, .tail = self.node } };
            return .{ .allocator = self.allocator, .node = new_node };
        }

        /// Build a list from a slice. Elements appear in slice order —
        /// `fromSlice(alloc, &.{1,2,3})` produces (1 :: 2 :: 3 :: nil).
        pub fn fromSlice(allocator: std.mem.Allocator, items: []const T) !Self {
            var list = Self.empty(allocator);
            var i: usize = items.len;
            while (i > 0) {
                i -= 1;
                list = try list.cons(items[i]);
            }
            return list;
        }

        /// Return the head of the list, or null if empty.
        pub fn head(self: Self) ?T {
            return switch (self.node.*) {
                .nil => null,
                .cons => |c| c.head,
            };
        }

        /// Return the tail of the list, or null if empty.
        /// Pure structural sharing — no allocation.
        pub fn tail(self: Self) ?Self {
            return switch (self.node.*) {
                .nil => null,
                .cons => |c| Self{
                    .allocator = self.allocator,
                    .node = c.tail,
                },
            };
        }

        /// True if the list is empty.
        pub fn isEmpty(self: Self) bool {
            return self.node.* == .nil;
        }

        /// Length of the list. O(n) walk.
        pub fn len(self: Self) usize {
            var count: usize = 0;
            var current: *const Node = self.node;
            while (true) {
                switch (current.*) {
                    .nil => return count,
                    .cons => |c| {
                        count += 1;
                        current = c.tail;
                    },
                }
            }
        }

        /// Return a forward iterator over the list.
        pub fn iterator(self: Self) Iterator {
            return .{ .current = self.node };
        }

        pub const Iterator = struct {
            current: *const Node,

            /// Return the next element, or null when exhausted.
            pub fn next(self: *Iterator) ?T {
                return switch (self.current.*) {
                    .nil => null,
                    .cons => |c| {
                        self.current = c.tail;
                        return c.head;
                    },
                };
            }
        };

        /// Collect all elements into a caller-provided slice.
        /// Asserts the slice is large enough.
        pub fn collect(self: Self, out: []T) void {
            var i: usize = 0;
            var it = self.iterator();
            while (it.next()) |elem| {
                out[i] = elem;
                i += 1;
            }
        }

        /// Destroy the list, freeing all cons nodes.
        /// WARNING: Only call this when no other list shares nodes with this one.
        /// In the arena model, prefer arena.deinit() instead.
        pub fn deinit(self: Self) void {
            var current: *const Node = self.node;
            while (true) {
                switch (current.*) {
                    .nil => return,
                    .cons => |c| {
                        const next = c.tail;
                        const ptr: *Node = @constCast(current);
                        self.allocator.destroy(ptr);
                        current = next;
                    },
                }
            }
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "empty list" {
    const L = List(i32);
    const empty_list = L.empty(testing.allocator);
    try testing.expect(empty_list.isEmpty());
    try testing.expectEqual(null, empty_list.head());
    try testing.expectEqual(null, empty_list.tail());
    try testing.expectEqual(@as(usize, 0), empty_list.len());
}

test "cons and head" {
    const L = List(i32);
    const e = L.empty(testing.allocator);
    const a = try e.cons(1);
    defer a.deinit();
    try testing.expect(!a.isEmpty());
    try testing.expectEqual(@as(i32, 1), a.head().?);
    try testing.expectEqual(@as(usize, 1), a.len());
}

test "cons multiple" {
    const L = List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(2);
    list = try list.cons(1);
    defer list.deinit();
    // list = [1, 2, 3]
    try testing.expectEqual(@as(i32, 1), list.head().?);
    try testing.expectEqual(@as(usize, 3), list.len());
    // tail = [2, 3]
    const t = list.tail().?;
    try testing.expectEqual(@as(i32, 2), t.head().?);
    try testing.expectEqual(@as(usize, 2), t.len());
}

test "structural sharing" {
    const L = List(i32);
    var a = L.empty(testing.allocator);
    a = try a.cons(3);
    a = try a.cons(2);
    a = try a.cons(1);
    // a = [1, 2, 3]

    // B = cons(0, A) = [0, 1, 2, 3]
    const b = try a.cons(0);
    defer b.deinit(); // B owns the full chain; don't call a.deinit() (shared nodes)

    // A still = [1, 2, 3] — unchanged
    try testing.expectEqual(@as(i32, 1), a.head().?);
    try testing.expectEqual(@as(usize, 3), a.len());

    // B = [0, 1, 2, 3]
    try testing.expectEqual(@as(i32, 0), b.head().?);
    try testing.expectEqual(@as(usize, 4), b.len());

    // B.tail points to the same node as A
    const b_tail = b.tail().?;
    try testing.expectEqual(@as(i32, 1), b_tail.head().?);
    try testing.expectEqual(a.node, b_tail.node);
}

test "iterator" {
    const L = List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(3);
    list = try list.cons(2);
    list = try list.cons(1);
    defer list.deinit();

    var it = list.iterator();
    try testing.expectEqual(@as(i32, 1), it.next().?);
    try testing.expectEqual(@as(i32, 2), it.next().?);
    try testing.expectEqual(@as(i32, 3), it.next().?);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(null, it.next());
}

test "collect into slice" {
    const L = List(i32);
    var list = L.empty(testing.allocator);
    list = try list.cons(30);
    list = try list.cons(20);
    list = try list.cons(10);
    defer list.deinit();

    var buf: [3]i32 = undefined;
    list.collect(&buf);
    try testing.expectEqual(@as(i32, 10), buf[0]);
    try testing.expectEqual(@as(i32, 20), buf[1]);
    try testing.expectEqual(@as(i32, 30), buf[2]);
}

test "large list construction" {
    const L = List(i32);
    var list = L.empty(testing.allocator);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        list = try list.cons(@intCast(i));
    }
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1000), list.len());
}

test "string list" {
    const L = List([]const u8);
    var list = L.empty(testing.allocator);
    list = try list.cons("three");
    list = try list.cons("two");
    list = try list.cons("one");
    defer list.deinit();

    try testing.expectEqualStrings("one", list.head().?);
    const t = list.tail().?;
    try testing.expectEqualStrings("two", t.head().?);
}

test "structural sharing — mutation proof" {
    // Verify that B and A share the same tail nodes in memory.
    // We use @constCast in the test to mutate through the shared pointer,
    // proving the nodes are physically the same.
    const L = List(i32);
    var a = L.empty(testing.allocator);
    a = try a.cons(30);
    a = try a.cons(20);
    a = try a.cons(10);
    // a = [10, 20, 30]

    const b = try a.cons(0);
    defer b.deinit();
    // b = [0, 10, 20, 30]

    // A.tail.node should point to the same memory as B.tail.tail.node
    const a_tail_node = a.tail().?.node;
    const b_second_node = b.tail().?.tail().?.node;
    try testing.expectEqual(a_tail_node, b_second_node);

    // Prove sharing: mutate through a's tail node and observe change in b
    const a_tail_mut: *List(i32).Node = @constCast(a_tail_node);
    switch (a_tail_mut.*) {
        .cons => |*c| {
            c.head = 999;
        },
        .nil => unreachable,
    }

    // B should now see the mutation: [0, 10, 999, 30]
    const b_val = b.tail().?.tail().?.head().?;
    try testing.expectEqual(@as(i32, 999), b_val);
}

test "empty iterator" {
    const L = List(i32);
    const e = L.empty(testing.allocator);
    var it = e.iterator();
    try testing.expectEqual(null, it.next());
}
