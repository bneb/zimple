const std = @import("std");
const hamt = @import("hamt.zig");

/// Persistent HashSet backed by a HAMT. Structural sharing — insert and
/// remove return new sets sharing unchanged subtrees.
pub fn HashSet(comptime K: type, comptime ctx: hamt.HashContext(K)) type {
    return struct {
        const Self = @This();
        const H = hamt.HashMap(K, void, ctx);
        const SetIter = H.Iterator;

        inner: H,

        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{ .inner = H.empty(allocator) };
        }

        pub fn len(self: Self) usize { return self.inner.len(); }
        pub fn isEmpty(self: Self) bool { return self.inner.isEmpty(); }

        pub fn contains(self: Self, key: K) bool {
            return self.inner.contains(key);
        }

        pub fn insert(self: Self, key: K) !Self {
            return .{ .inner = try self.inner.put(key, {}) };
        }

        pub fn remove(self: Self, key: K) !Self {
            return .{ .inner = try self.inner.remove(key) };
        }

        pub fn fromSlice(allocator: std.mem.Allocator, keys: []const K) !Self {
            var s = Self.empty(allocator);
            for (keys) |k| s = try s.insert(k);
            return s;
        }

        /// Union: all elements from both sets.
        pub fn unionWith(self: Self, other: Self) !Self {
            var result = self;
            var it = other.inner.iterator();
            while (it.next()) |entry| {
                result = try result.insert(entry.key);
            }
            return result;
        }

        /// Intersection: elements present in both sets.
        pub fn intersect(self: Self, other: Self) !Self {
            var result = Self.empty(self.inner.allocator);
            var it = self.inner.iterator();
            while (it.next()) |entry| {
                if (other.contains(entry.key)) {
                    result = try result.insert(entry.key);
                }
            }
            return result;
        }

        pub fn iterator(self: Self) SetIter { return self.inner.iterator(); }
        pub fn deinit(self: Self) void { self.inner.deinit(); }
    };
}

test {
    _ = @import("hashset_test.zig");
}
