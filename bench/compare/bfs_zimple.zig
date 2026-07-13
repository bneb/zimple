// BFS distances — Zimple
// Given adjacency list, compute distance from start node to all reachable nodes.
const std = @import("std");
const zimple = @import("zimple");

pub fn bfs(allocator: std.mem.Allocator, edges: []const [2]i32, start: i32) !zimple.HashMap(i32, i32, zimple.autoHash(i32)) {
    var dist = zimple.HashMap(i32, i32, zimple.autoHash(i32)).empty(allocator);
    dist = try dist.put(start, 0);

    var queue = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer queue.deinit(allocator);
    try queue.append(allocator, start);

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        const d = (dist.get(current) orelse 0) + 1;

        for (edges) |edge| {
            if (edge[0] == current) {
                const neighbor = edge[1];
                if (!dist.contains(neighbor)) {
                    dist = try dist.put(neighbor, d);
                    try queue.append(allocator, neighbor);
                }
            }
        }
    }
    return dist;
}
