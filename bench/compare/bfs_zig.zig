// BFS distances — raw Zig
// Given adjacency list, compute distance from start node to all reachable nodes.
const std = @import("std");

pub fn bfs(allocator: std.mem.Allocator, edges: []const [2]i32, start: i32) !std.AutoHashMap(i32, i32) {
    var dist = std.AutoHashMap(i32, i32).init(allocator);
    try dist.put(start, 0);

    var queue = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer queue.deinit(allocator);
    try queue.append(allocator, start);

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        const d = dist.get(current).? + 1;

        for (edges) |edge| {
            if (edge[0] == current) {
                const neighbor = edge[1];
                if (!dist.contains(neighbor)) {
                    try dist.put(neighbor, d);
                    try queue.append(allocator, neighbor);
                }
            }
        }
    }
    return dist;
}
