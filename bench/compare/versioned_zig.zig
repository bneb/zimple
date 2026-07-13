// Versioned pipeline — raw Zig
// Build a vector, transform through 4 steps, keep ALL versions alive.
// This is where structural sharing makes a difference.
const std = @import("std");

pub fn run(allocator: std.mem.Allocator, n: usize) !void {
    // Build initial vector — must copy at each step to preserve history
    var v0 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer v0.deinit(allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) { try v0.append(allocator, @intCast(i)); }

    // Step 1: filter odds — copy to new array
    var v1 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer v1.deinit(allocator);
    for (v0.items) |x| if (@mod(x, 2) != 0) try v1.append(allocator, x);

    // Step 2: square — copy to new array
    var v2 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer v2.deinit(allocator);
    for (v1.items) |x| try v2.append(allocator, x * x);

    // Step 3: keep > threshold — copy to new array
    var v3 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer v3.deinit(allocator);
    for (v2.items) |x| if (x > 1000) try v3.append(allocator, x);

    // Step 4: double — copy to new array
    var v4 = try std.ArrayList(i32).initCapacity(allocator, 0);
    defer v4.deinit(allocator);
    for (v3.items) |x| try v4.append(allocator, x * 2);

    _ = .{ v0, v1, v2, v3, v4 };
}
