const std = @import("std");

/// Persistent bitmapped trie vector with structural sharing.
/// 32-way branching gives O(log_32 N) access and updates.
/// `set` and `pushBack` return new vectors sharing unchanged subtrees.
pub fn Vector(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Element = T;
        const BITS: usize = 5;
        const BRANCH: usize = 32;

        pub const Node = union(enum) {
            internal: struct {
                count: usize,
                bitmap: u32,
                slots: [BRANCH]?*const Node,
            },
            leaf: struct {
                count: usize,
                bitmap: u32,
                values: [BRANCH]T,
            },
        };

        allocator: std.mem.Allocator,
        root: ?*const Node,
        size: usize,
        shift: usize,

        pub fn empty(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .root = null, .size = 0, .shift = 0 };
        }

        /// Build a vector from a slice bottom-up. O(n) node allocations
        /// instead of O(n log n) when using repeated pushBack.
        pub fn fromSlice(allocator: std.mem.Allocator, items: []const T) !Self {
            if (items.len == 0) return Self.empty(allocator);
            if (items.len <= BRANCH) {
                const leaf = try allocator.create(Node);
                var values: [BRANCH]T = undefined;
                @memcpy(values[0..items.len], items);
                leaf.* = .{ .leaf = .{ .count = items.len, .bitmap = (@as(u32, 1) << @intCast(items.len)) - 1, .values = values } };
                return .{ .allocator = allocator, .root = leaf, .size = items.len, .shift = 0 };
            }

            const leaf_count = (items.len + BRANCH - 1) / BRANCH;
            var level_nodes = try std.ArrayList(*const Node).initCapacity(allocator, leaf_count);

            var offset: usize = 0;
            while (offset < items.len) {
                const chunk_size = @min(BRANCH, items.len - offset);
                const leaf = try allocator.create(Node);
                var values: [BRANCH]T = undefined;
                @memcpy(values[0..chunk_size], items[offset..][0..chunk_size]);
                leaf.* = .{ .leaf = .{ .count = chunk_size, .bitmap = (@as(u32, 1) << @intCast(chunk_size)) - 1, .values = values } };
                try level_nodes.append(allocator, leaf);
                offset += chunk_size;
            }

            var shift: usize = BITS;
            while (level_nodes.items.len > 1) {
                const parent_count = (level_nodes.items.len + BRANCH - 1) / BRANCH;
                var parents = try std.ArrayList(*const Node).initCapacity(allocator, parent_count);

                var i: usize = 0;
                while (i < level_nodes.items.len) {
                    const chunk_size = @min(BRANCH, level_nodes.items.len - i);
                    const internal = try allocator.create(Node);
                    var slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
                    @memcpy(slots[0..chunk_size], level_nodes.items[i..][0..chunk_size]);
                    var bitmap: u32 = 0;
                    for (0..chunk_size) |j| bitmap |= @as(u32, 1) << @intCast(j);
                    internal.* = .{ .internal = .{ .count = chunk_size, .bitmap = bitmap, .slots = slots } };
                    try parents.append(allocator, internal);
                    i += chunk_size;
                }

                level_nodes.deinit(allocator);
                level_nodes = parents;
                shift += BITS;
            }

            const root = level_nodes.items[0];
            return .{ .allocator = allocator, .root = root, .size = items.len, .shift = shift - BITS };
        }

        pub fn len(self: Self) usize {
            return self.size;
        }

        pub fn isEmpty(self: Self) bool {
            return self.size == 0;
        }

        pub fn get(self: Self, index: usize) ?T {
            if (index >= self.size) return null;
            const node = self.root orelse return null;
            return getRecursive(node, self.shift, index);
        }

        fn getRecursive(node: *const Node, shift: usize, index: usize) ?T {
            switch (node.*) {
                .leaf => |leaf| {
                    const idx = index & (BRANCH - 1);
                    return if (idx < leaf.count) leaf.values[idx] else null;
                },
                .internal => |internal| {
                    const idx = (index >> @as(u6, @intCast(shift))) & (BRANCH - 1);
                    const child = internal.slots[idx] orelse return null;
                    return getRecursive(child, shift - BITS, index);
                },
            }
        }

        pub fn set(self: Self, index: usize, value: T) !Self {
            const node = self.root orelse return error.EmptyVector;
            if (index >= self.size) return error.IndexOutOfBounds;
            const new_root = try setRecursive(self.allocator, node, self.shift, index, value);
            return .{ .allocator = self.allocator, .root = new_root, .size = self.size, .shift = self.shift };
        }

        fn setRecursive(allocator: std.mem.Allocator, node: *const Node, shift: usize, index: usize, value: T) !*const Node {
            switch (node.*) {
                .leaf => |leaf| {
                    const idx = index & (BRANCH - 1);
                    const new_node = try allocator.create(Node);
                    new_node.* = .{ .leaf = .{
                        .count = leaf.count,
                        .bitmap = leaf.bitmap,
                        .values = copyValues(&leaf.values),
                    } };
                    new_node.leaf.values[idx] = value;
                    return new_node;
                },
                .internal => |internal| {
                    const idx = (index >> @as(u6, @intCast(shift))) & (BRANCH - 1);
                    const child = internal.slots[idx] orelse return error.InvalidPath;
                    const new_child = try setRecursive(allocator, child, shift - BITS, index, value);
                    const nr = try allocator.create(Node);
                    nr.* = .{ .internal = .{ .count = internal.count, .bitmap = internal.bitmap, .slots = copySlots(&internal.slots) } };
                    nr.internal.slots[idx] = new_child;
                    return nr;
                },
            }
        }

        pub fn pushBack(self: Self, value: T) !Self {
            if (self.root == null) {
                const leaf = try allocLeaf(self.allocator, value);
                return .{ .allocator = self.allocator, .root = leaf, .size = 1, .shift = 0 };
            }

            var root = self.root.?;
            var shift = self.shift;

            if (self.size == (@as(usize, 1) << @intCast(self.shift + BITS))) {
                const nr = try self.allocator.create(Node);
                var slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
                slots[0] = self.root;
                nr.* = .{ .internal = .{ .count = 1, .bitmap = 1 << 0, .slots = slots } };
                root = nr;
                shift += BITS;
            }

            const new_root = try pushBackRecursive(self.allocator, root, shift, self.size, value);
            return .{ .allocator = self.allocator, .root = new_root, .size = self.size + 1, .shift = shift };
        }

        fn pushBackRecursive(allocator: std.mem.Allocator, node: *const Node, shift: usize, index: usize, value: T) !*const Node {
            if (shift == 0) return pushBackLeaf(allocator, node, value);
            const child_idx = (index >> @as(u6, @intCast(shift))) & (BRANCH - 1);
            switch (node.*) {
                .internal => |internal| {
                    const new_child = if (internal.slots[child_idx]) |child|
                        try pushBackRecursive(allocator, child, shift - BITS, index, value)
                    else
                        try createPath(allocator, shift - BITS, index, value);
                    var slots = copySlots(&internal.slots);
                    slots[child_idx] = new_child;
                    const nr = try allocator.create(Node);
                    nr.* = .{ .internal = .{
                        .count = if (internal.slots[child_idx] != null) internal.count else internal.count + 1,
                        .bitmap = internal.bitmap | (@as(u32, 1) << @intCast(child_idx)),
                        .slots = slots,
                    } };
                    return nr;
                },
                .leaf => unreachable,
            }
        }

        fn pushBackLeaf(allocator: std.mem.Allocator, node: *const Node, value: T) !*const Node {
            switch (node.*) {
                .leaf => |leaf| {
                    if (leaf.count < BRANCH) {
                        var values = copyValues(&leaf.values);
                        values[leaf.count] = value;
                        const nr = try allocator.create(Node);
                        nr.* = .{ .leaf = .{ .count = leaf.count + 1, .bitmap = leaf.bitmap | (@as(u32, 1) << @intCast(leaf.count)), .values = values } };
                        return nr;
                    }
                    const new_leaf = try allocLeaf(allocator, value);
                    const nr = try allocator.create(Node);
                    var slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
                    slots[0] = node;
                    slots[1] = new_leaf;
                    nr.* = .{ .internal = .{ .count = 2, .bitmap = (1 << 0) | (1 << 1), .slots = slots } };
                    return nr;
                },
                .internal => unreachable,
            }
        }

        fn createPath(allocator: std.mem.Allocator, shift: usize, index: usize, value: T) !*const Node {
            if (shift == 0) return allocLeaf(allocator, value);
            const child_idx = (index >> @as(u6, @intCast(shift))) & (BRANCH - 1);
            const child = try createPath(allocator, shift - BITS, index, value);
            const nr = try allocator.create(Node);
            var slots: [BRANCH]?*const Node = [_]?*const Node{null} ** BRANCH;
            slots[child_idx] = child;
            nr.* = .{ .internal = .{ .count = 1, .bitmap = @as(u32, 1) << @intCast(child_idx), .slots = slots } };
            return nr;
        }

        fn allocLeaf(allocator: std.mem.Allocator, value: T) !*const Node {
            const leaf = try allocator.create(Node);
            var values: [BRANCH]T = undefined;
            values[0] = value;
            leaf.* = .{ .leaf = .{ .count = 1, .bitmap = 1, .values = values } };
            return leaf;
        }

        fn copyValues(src: *const [BRANCH]T) [BRANCH]T {
            var dest: [BRANCH]T = undefined;
            @memcpy(&dest, src);
            return dest;
        }

        fn copySlots(src: *const [BRANCH]?*const Node) [BRANCH]?*const Node {
            var dest: [BRANCH]?*const Node = undefined;
            @memcpy(&dest, src);
            return dest;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .root = self.root, .shift = self.shift, .size = self.size };
        }

        pub const Iterator = struct {
            root: ?*const Node,
            shift: usize,
            size: usize,
            index: usize = 0,
            stack: [12]StackFrame = [_]StackFrame{.{ .node = undefined, .child_idx = 0 }} ** 12,
            stack_depth: usize = 0,

            const StackFrame = struct { node: *const Node, child_idx: usize };

            pub fn next(self: *Iterator) ?T {
                if (self.index >= self.size) return null;
                if (self.stack_depth == 0) {
                    const node = self.root orelse return null;
                    self.stack[0] = .{ .node = node, .child_idx = 0 };
                    self.stack_depth = 1;
                }
                while (self.stack_depth > 0) {
                    const top = &self.stack[self.stack_depth - 1];
                    switch (top.node.*) {
                        .leaf => |leaf| {
                            if (top.child_idx < leaf.count) {
                                defer top.child_idx += 1;
                                self.index += 1;
                                return leaf.values[top.child_idx];
                            }
                            self.stack_depth -= 1;
                        },
                        .internal => |internal| {
                            if (tryDescend(self, top, internal)) continue;
                            self.stack_depth -= 1;
                        },
                    }
                }
                return null;
            }

            fn tryDescend(it: *Iterator, top: *StackFrame, internal: anytype) bool {
                while (top.child_idx < BRANCH) : (top.child_idx += 1) {
                    if (internal.slots[top.child_idx]) |child| {
                        top.child_idx += 1;
                        if (it.stack_depth >= it.stack.len) return false;
                        it.stack[it.stack_depth] = .{ .node = child, .child_idx = 0 };
                        it.stack_depth += 1;
                        return true;
                    }
                }
                return false;
            }
        };

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

        pub fn simdMapLeaf(
            comptime U: type,
            allocator: std.mem.Allocator,
            node: *const Node,
            map_fn: *const fn (@Vector(4, T)) @Vector(4, U),
            scalar_map_fn: *const fn (T) U,
        ) !*const Vector(U).Node {
            const leaf = switch (node.*) {
                .leaf => |*l| l,
                .internal => return error.NotALeaf,
            };

            const OutNode = Vector(U).Node;
            const nr = try allocator.create(OutNode);
            var out_values: [BRANCH]U = undefined;

            const builtin = @import("builtin");
            const use_simd = builtin.cpu.arch == .aarch64;

            if (use_simd) {
                var i: usize = 0;
                while (i + 4 <= BRANCH) : (i += 4) {
                    const vec: @Vector(4, T) = .{
                        leaf.values[i],
                        leaf.values[i + 1],
                        leaf.values[i + 2],
                        leaf.values[i + 3],
                    };
                    const res = map_fn(vec);
                    out_values[i] = res[0];
                    out_values[i + 1] = res[1];
                    out_values[i + 2] = res[2];
                    out_values[i + 3] = res[3];
                }
            } else {
                for (leaf.values, 0..) |v, i| {
                    out_values[i] = scalar_map_fn(v);
                }
            }

            nr.* = .{ .leaf = .{ .count = leaf.count, .bitmap = leaf.bitmap, .values = out_values } };
            return nr;
        }

        pub fn simdReduceLeaf(
            comptime R: type,
            node: *const Node,
            reduce_fn: *const fn (@Vector(4, R), @Vector(4, T)) @Vector(4, R),
            scalar_reduce_fn: *const fn (R, T) R,
            merge_fn: *const fn (R, R) R,
            identity: R,
        ) R {
            const leaf = switch (node.*) {
                .leaf => |*l| l,
                .internal => @panic("Not a leaf"),
            };

            const builtin = @import("builtin");
            const use_simd = builtin.cpu.arch == .aarch64;

            var sum = identity;

            if (use_simd) {
                var vec_sum: @Vector(4, R) = .{ identity, identity, identity, identity };
                var i: usize = 0;
                // Only process full SIMD blocks up to count
                while (i + 4 <= leaf.count) : (i += 4) {
                    const vec: @Vector(4, T) = .{
                        leaf.values[i],
                        leaf.values[i + 1],
                        leaf.values[i + 2],
                        leaf.values[i + 3],
                    };
                    vec_sum = reduce_fn(vec_sum, vec);
                }
                
                sum = merge_fn(sum, vec_sum[0]);
                sum = merge_fn(sum, vec_sum[1]);
                sum = merge_fn(sum, vec_sum[2]);
                sum = merge_fn(sum, vec_sum[3]);

                // Process remaining elements with scalar
                while (i < leaf.count) : (i += 1) {
                    sum = scalar_reduce_fn(sum, leaf.values[i]);
                }
            } else {
                var i: usize = 0;
                while (i < leaf.count) : (i += 1) {
                    sum = scalar_reduce_fn(sum, leaf.values[i]);
                }
            }

            return sum;
        }
    };
}
