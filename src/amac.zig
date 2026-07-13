const std = @import("std");
const hamt = @import("hamt.zig");

/// Asynchronous Memory Access Chaining (AMAC) engine for bulk lookups.
/// It multiplexes multiple queries through a state machine, issuing
/// prefetches before pointer-chasing to hide memory latency.
pub fn AmacEngine(comptime K: type, comptime V: type, comptime ctx: hamt.HashContext(K), comptime BATCH_SIZE: usize) type {
    return struct {
        const Node = hamt.HashMap(K, V, ctx).Node;
        const BITS = hamt.HashMap(K, V, ctx).BITS;
        const BRANCH = hamt.HashMap(K, V, ctx).BRANCH;
        
        const State = struct {
            key: K,
            hash: u64,
            node: *const Node,
            shift: u5,
            out_idx: usize,
        };

        pub fn bulkGet(root: ?*const Node, keys: []const K, out_results: []?V) void {
            if (root == null) {
                for (out_results) |*res| res.* = null;
                return;
            }
            const r = root.?;

            var states: [BATCH_SIZE]State = undefined;
            var active_count: usize = 0;
            var next_in: usize = 0;
            
            // Initial fill phase
            while (active_count < BATCH_SIZE and next_in < keys.len) {
                const k = keys[next_in];
                states[active_count] = .{
                    .key = k,
                    .hash = ctx.hash(k),
                    .node = r,
                    .shift = 0,
                    .out_idx = next_in,
                };
                @prefetch(r, .{ .rw = .read, .locality = 3, .cache = .data });
                active_count += 1;
                next_in += 1;
            }

            // Processing phase
            while (active_count > 0) {
                var i: usize = 0;
                while (i < active_count) {
                    var s = &states[i];
                    
                    var next_node: ?*const Node = null;
                    var done = false;
                    var result: ?V = null;
                    
                    const idx: u5 = @truncate((s.hash >> s.shift) & (BRANCH - 1));
                    
                    switch (s.node.*) {
                        .leaf => |*leaf| {
                            done = true;
                            const mask = @as(u32, 1) << idx;
                            if (leaf.bitmap & mask != 0) {
                                if (ctx.eql(leaf.keys[idx], s.key)) {
                                    result = leaf.values[idx];
                                } else {
                                    // Hash collision handling
                                    for (leaf.keys, 0..) |lk, j| {
                                        if (leaf.bitmap & (@as(u32, 1) << @intCast(j)) != 0) {
                                            if (ctx.eql(lk, s.key)) {
                                                result = leaf.values[j];
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        .internal => |*internal| {
                            const child = internal.slots[idx];
                            if (child) |c| {
                                next_node = c;
                                s.shift += BITS;
                            } else {
                                done = true;
                            }
                        }
                    }
                    
                    if (done) {
                        out_results[s.out_idx] = result;
                        
                        // Try to replace with a new query to keep pipeline full
                        if (next_in < keys.len) {
                            const k = keys[next_in];
                            s.* = .{
                                .key = k,
                                .hash = ctx.hash(k),
                                .node = r,
                                .shift = 0,
                                .out_idx = next_in,
                            };
                            @prefetch(r, .{ .rw = .read, .locality = 3, .cache = .data });
                            next_in += 1;
                            i += 1;
                        } else {
                            // Swap-remove active state
                            states[i] = states[active_count - 1];
                            active_count -= 1;
                            // Do not increment `i`, process the swapped-in state next
                        }
                    } else {
                        // Advance to the next level
                        s.node = next_node.?;
                        @prefetch(s.node, .{ .rw = .read, .locality = 3, .cache = .data });
                        i += 1;
                    }
                }
            }
        }
    };
}

test {
    _ = @import("amac_test.zig");
}
