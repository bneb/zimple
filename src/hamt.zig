const std = @import("std");

pub fn HashContext(comptime K: type) type {
    return struct {
        hash: *const fn (key: K) u64,
        eql: *const fn (a: K, b: K) bool,
    };
}

pub fn autoHash(comptime K: type) HashContext(K) {
    return .{
        .hash = struct {
            fn h(key: K) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, key);
                return hasher.final();
            }
        }.h,
        .eql = struct {
            fn e(a: K, b: K) bool {
                return std.meta.eql(a, b);
            }
        }.e,
    };
}

/// Persistent HAMT with structural sharing. 32-way branching.
pub fn HashMap(comptime K: type, comptime V: type, comptime ctx: HashContext(K)) type {
    return struct {
        const Self = @This();
        pub const BITS: u5 = 5;
        pub const BRANCH: u32 = 32;

        pub const Entry = struct { key: K, value: V };

        pub const Node = union(enum) {
            internal: struct {
                bitmap: u32,
                slots: [BRANCH]?*const Node,
            },
            leaf: struct {
                bitmap: u32,
                keys: [BRANCH]K,
                values: [BRANCH]V,
            },
        };

        allocator: std.mem.Allocator,
        root: ?*const Node,
        count: usize,

        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .root = null, .count = 0 };
        }

        pub fn len(self: Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        pub fn get(self: Self, key: K) ?V {
            const root = self.root orelse return null;
            return getRecursive(root, ctx.hash(key), 0, key);
        }

        fn getRecursive(node: *const Node, hash: u64, shift: u5, key: K) ?V {
            const idx: u5 = @truncate((hash >> shift) & (BRANCH - 1));

            switch (node.*) {
                .leaf => |leaf| {
                    const mask = @as(u32, 1) << idx;
                    if (leaf.bitmap & mask == 0) return null;
                    if (ctx.eql(leaf.keys[idx], key)) return leaf.values[idx];
                    // Hash collision: different key, same hash → search
                    for (leaf.keys, leaf.values, 0..) |k, v, i| {
                        if (leaf.bitmap & (@as(u32, 1) << @intCast(i)) != 0) {
                            if (ctx.eql(k, key)) return v;
                        }
                    }
                    return null;
                },
                .internal => |internal| {
                    const child = internal.slots[idx] orelse return null;
                    return getRecursive(child, hash, shift + BITS, key);
                },
            }
        }

        pub fn contains(self: Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn put(self: Self, key: K, value: V) !Self {
            const h = ctx.hash(key);
            if (self.root) |r| {
                const existed = getRecursive(r, h, 0, key) != null;
                const new_root = try putRecursive(self.allocator, r, h, 0, key, value);
                return .{
                    .allocator = self.allocator,
                    .root = new_root,
                    .count = if (existed) self.count else self.count + 1,
                };
            } else {
                const leaf = try allocLeaf(self.allocator, h, 0, key, value);
                return .{ .allocator = self.allocator, .root = leaf, .count = 1 };
            }
        }

        fn putRecursive(allocator: std.mem.Allocator, node: *const Node, hash: u64, shift: u5, key: K, value: V) !*const Node {
            const idx: u5 = @truncate((hash >> shift) & (BRANCH - 1));
            const mask = @as(u32, 1) << idx;

            switch (node.*) {
                .leaf => |leaf| {
                    // Same slot free? Insert here.
                    if (leaf.bitmap & mask == 0) {
                        var keys = leaf.keys;
                        var values = leaf.values;
                        keys[idx] = key;
                        values[idx] = value;
                        const nr = try allocator.create(Node);
                        nr.* = .{ .leaf = .{ .bitmap = leaf.bitmap | mask, .keys = keys, .values = values } };
                        return nr;
                    }
                    // Slot occupied — check if same key (replace)
                    if (ctx.eql(leaf.keys[idx], key)) {
                        var values = leaf.values;
                        values[idx] = value;
                        const nr = try allocator.create(Node);
                        nr.* = .{ .leaf = .{ .bitmap = leaf.bitmap, .keys = leaf.keys, .values = values } };
                        return nr;
                    }
                    // Hash collision at slot `idx`. Promote to internal node
                    // at the current shift. Non-colliding slots become direct
                    // children (one-entry leaves at shift+BITS). The colliding
                    // slot gets a sub-tree holding both old and new keys.
                    const nr = try allocator.create(Node);
                    var child_slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
                    var child_bitmap: u32 = 0;

                    for (leaf.keys, leaf.values, 0..) |k, v, i| {
                        if (leaf.bitmap & (@as(u32, 1) << @intCast(i)) == 0) continue;
                        if (i == idx) continue; // handled below
                        const child = try allocLeaf(allocator, ctx.hash(k), shift + BITS, k, v);
                        child_slots[i] = child;
                        child_bitmap |= @as(u32, 1) << @intCast(i);
                    }

                    // Handle collision slot: re-insert old + new keys at shift+BITS
                    const sub = try allocator.create(Node);
                    sub.* = .{ .internal = .{ .bitmap = 0, .slots = [_]?*const Node{null} ** BRANCH } };
                    var sub_current = try putRecursiveInto(allocator, sub, ctx.hash(leaf.keys[idx]), shift + BITS, leaf.keys[idx], leaf.values[idx]);
                    sub_current = try putRecursiveInto(allocator, sub_current, hash, shift + BITS, key, value);
                    child_slots[idx] = sub_current;
                    child_bitmap |= mask;

                    nr.* = .{ .internal = .{ .bitmap = child_bitmap, .slots = child_slots } };
                    return nr;
                },
                .internal => |internal| {
                    const child = internal.slots[idx];
                    var slots = copySlots(&internal.slots);

                    if (child) |c| {
                        slots[idx] = try putRecursive(allocator, c, hash, shift + BITS, key, value);
                    } else {
                        slots[idx] = try allocLeaf(allocator, hash, shift + BITS, key, value);
                    }
                    const nr = try allocator.create(Node);
                    nr.* = .{ .internal = .{ .bitmap = internal.bitmap | mask, .slots = slots } };
                    return nr;
                },
            }
        }

        /// Like putRecursive but always succeeds (no count tracking needed for
        /// re-inserting existing entries during leaf promotion).
        fn putRecursiveInto(allocator: std.mem.Allocator, node: *const Node, hash: u64, shift: u5, key: K, value: V) !*const Node {
            const idx: u5 = @truncate((hash >> shift) & (BRANCH - 1));
            const mask = @as(u32, 1) << idx;

            switch (node.*) {
                .leaf => {
                    if (node.leaf.bitmap & mask == 0) {
                        var keys: [BRANCH]K = undefined;
                        var values: [BRANCH]V = undefined;
                        @memcpy(&keys, &node.leaf.keys);
                        @memcpy(&values, &node.leaf.values);
                        keys[idx] = key;
                        values[idx] = value;
                        const nr = try allocator.create(Node);
                        nr.* = .{ .leaf = .{ .bitmap = node.leaf.bitmap | mask, .keys = keys, .values = values } };
                        return nr;
                    }
                    // Collision at slot idx — promote non-colliding entries as
                    // direct children, re-insert colliding ones at shift+BITS.
                    const nr = try allocator.create(Node);
                    var child_slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
                    var child_bitmap: u32 = 0;

                    for (node.leaf.keys, node.leaf.values, 0..) |k, v, i| {
                        if (node.leaf.bitmap & (@as(u32, 1) << @intCast(i)) == 0) continue;
                        if (i == idx) continue;
                        const child = try allocLeaf(allocator, ctx.hash(k), shift + BITS, k, v);
                        child_slots[i] = child;
                        child_bitmap |= @as(u32, 1) << @intCast(i);
                    }

                    const sub = try allocator.create(Node);
                    sub.* = .{ .internal = .{ .bitmap = 0, .slots = [_]?*const Node{null} ** BRANCH } };
                    var sub_cur = try putRecursiveInto(allocator, sub, ctx.hash(node.leaf.keys[idx]), shift + BITS, node.leaf.keys[idx], node.leaf.values[idx]);
                    sub_cur = try putRecursiveInto(allocator, sub_cur, hash, shift + BITS, key, value);
                    child_slots[idx] = sub_cur;
                    child_bitmap |= mask;

                    nr.* = .{ .internal = .{ .bitmap = child_bitmap, .slots = child_slots } };
                    return nr;
                },
                .internal => {
                    var slots = copySlots(&node.internal.slots);
                    if (node.internal.slots[idx]) |c| {
                        slots[idx] = try putRecursiveInto(allocator, c, hash, shift + BITS, key, value);
                    } else {
                        slots[idx] = try allocLeaf(allocator, hash, shift + BITS, key, value);
                    }
                    const nr = try allocator.create(Node);
                    nr.* = .{ .internal = .{ .bitmap = node.internal.bitmap | mask, .slots = slots } };
                    return nr;
                },
            }
        }

        pub fn remove(self: Self, key: K) !Self {
            const root = self.root orelse return error.KeyNotFound;
            const h = ctx.hash(key);
            if (getRecursive(root, h, 0, key) == null) return error.KeyNotFound;
            const new_root = try removeRecursive(self.allocator, root, h, 0, key);
            if (new_root) |r| {
                return .{ .allocator = self.allocator, .root = if (isEmptyNode(r)) null else r, .count = self.count - 1 };
            } else {
                return .{ .allocator = self.allocator, .root = null, .count = 0 };
            }
        }

        fn removeRecursive(allocator: std.mem.Allocator, node: *const Node, hash: u64, shift: u5, key: K) !?*const Node {
            const idx: u5 = @truncate((hash >> shift) & (BRANCH - 1));
            const mask = @as(u32, 1) << idx;

            switch (node.*) {
                .leaf => |leaf| {
                    if (leaf.bitmap & mask == 0) return error.KeyNotFound;
                    if (!ctx.eql(leaf.keys[idx], key)) {
                        // Hash collision — search for the right key
                        for (leaf.keys, 0..) |k, i| {
                            if (leaf.bitmap & (@as(u32, 1) << @intCast(i)) != 0) {
                                if (ctx.eql(k, key)) {
                                    var new_keys = leaf.keys;
                                    var new_values = leaf.values;
                                    new_keys[i] = undefined;
                                    new_values[i] = undefined;
                                    const new_bitmap = leaf.bitmap & ~(@as(u32, 1) << @intCast(i));
                                    if (new_bitmap == 0) return null; // empty leaf
                                    const nr = try allocator.create(Node);
                                    nr.* = .{ .leaf = .{ .bitmap = new_bitmap, .keys = new_keys, .values = new_values } };
                                    return nr;
                                }
                            }
                        }
                        return error.KeyNotFound;
                    }
                    // Direct match
                    var new_keys = leaf.keys;
                    var new_values = leaf.values;
                    new_keys[idx] = undefined;
                    new_values[idx] = undefined;
                    const new_bitmap = leaf.bitmap & ~mask;
                    if (new_bitmap == 0) return null; // empty leaf → signal parent
                    const nr = try allocator.create(Node);
                    nr.* = .{ .leaf = .{ .bitmap = new_bitmap, .keys = new_keys, .values = new_values } };
                    return nr;
                },
                .internal => |internal| {
                    const child = internal.slots[idx] orelse return error.KeyNotFound;
                    const new_child = try removeRecursive(allocator, child, hash, shift + BITS, key);
                    var slots = copySlots(&internal.slots);
                    const new_bitmap = if (new_child != null)
                        internal.bitmap
                    else
                        internal.bitmap & ~mask;
                    slots[idx] = new_child;

                    // Collapse: only one child left → promote it
                    const child_count = @popCount(new_bitmap);
                    if (child_count == 1) {
                        const remaining_idx = @ctz(new_bitmap);
                        return slots[remaining_idx];
                    }
                    if (child_count == 0) return null;
                    const nr = try allocator.create(Node);
                    nr.* = .{ .internal = .{ .bitmap = new_bitmap, .slots = slots } };
                    return nr;
                },
            }
        }

        fn isEmptyNode(node: *const Node) bool {
            return switch (node.*) {
                .leaf => |l| l.bitmap == 0,
                .internal => |i| i.bitmap == 0,
            };
        }

        fn allocLeaf(allocator: std.mem.Allocator, hash: u64, shift: u5, key: K, value: V) !*const Node {
            const idx: u5 = @truncate((hash >> shift) & (BRANCH - 1));
            const leaf = try allocator.create(Node);
            var keys: [BRANCH]K = undefined;
            var values: [BRANCH]V = undefined;
            keys[idx] = key;
            values[idx] = value;
            leaf.* = .{ .leaf = .{ .bitmap = @as(u32, 1) << idx, .keys = keys, .values = values } };
            return leaf;
        }

        fn copySlots(src: *const [BRANCH]?*const Node) [BRANCH]?*const Node {
            var dest: [BRANCH]?*const Node = undefined;
            @memcpy(&dest, src);
            return dest;
        }

        pub fn fromSlice(allocator: std.mem.Allocator, entries: []const Entry) !Self {
            var map = Self.empty(allocator);
            for (entries) |entry| {
                map = try map.put(entry.key, entry.value);
            }
            return map;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .root = self.root };
        }

        pub const Iterator = struct {
            root: ?*const Node,
            stack: [12]StackFrame = [_]StackFrame{.{ .node = undefined, .slot = 0 }} ** 12,
            depth: usize = 0,
            started: bool = false,

            const StackFrame = struct { node: *const Node, slot: u32 };

            pub fn next(self: *Iterator) ?Entry {
                if (self.root == null) return null;
                if (!self.started) {
                    self.stack[0] = .{ .node = self.root.?, .slot = 0 };
                    self.depth = 1;
                    self.started = true;
                }
                while (self.depth > 0) {
                    const top = &self.stack[self.depth - 1];
                    switch (top.node.*) {
                        .leaf => |leaf| {
                            while (top.slot < BRANCH) : (top.slot += 1) {
                                if (leaf.bitmap & (@as(u32, 1) << @intCast(top.slot)) != 0) {
                                    const entry = Entry{ .key = leaf.keys[top.slot], .value = leaf.values[top.slot] };
                                    top.slot += 1;
                                    return entry;
                                }
                            }
                            self.depth -= 1;
                        },
                        .internal => |internal| {
                            while (top.slot < BRANCH) : (top.slot += 1) {
                                if (internal.slots[top.slot]) |child| {
                                    const next_slot = top.slot + 1;
                                    if (self.depth < self.stack.len) {
                                        self.stack[self.depth] = .{ .node = child, .slot = 0 };
                                        self.depth += 1;
                                    }
                                    top.slot = next_slot;
                                    break;
                                }
                            }
                            if (top.slot >= BRANCH) {
                                self.depth -= 1;
                            }
                        },
                    }
                }
                return null;
            }
        };

        pub fn bulkGet(self: Self, comptime BATCH_SIZE: usize, keys: []const K, out_results: []?V) void {
            const Engine = @import("root.zig").AmacEngine(K, V, ctx, BATCH_SIZE);
            Engine.bulkGet(self.root, keys, out_results);
        }

        pub fn deinit(self: Self) void {
            if (self.root) |r| deinitNode(self.allocator, r);
        }

        fn deinitNode(allocator: std.mem.Allocator, node: *const Node) void {
            switch (node.*) {
                .leaf => {},
                .internal => |internal| {
                    for (internal.slots) |child| {
                        if (child) |c| deinitNode(allocator, c);
                    }
                },
            }
            allocator.destroy(@constCast(node));
        }
    };
}

test {
    _ = @import("hamt_test.zig");
}
