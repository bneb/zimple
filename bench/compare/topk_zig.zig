// Top-K — raw Zig
// Keep positives, square them, sort descending, take top K.
const std = @import("std");

pub fn topK(allocator: std.mem.Allocator, input: []const i32, k: usize) ![]i32 {
    var result = try std.ArrayList(i32).initCapacity(allocator, 0);

    // Filter positives, map to squares
    for (input) |x| {
        if (x > 0) {
            try result.append(allocator, x * x);
        }
    }

    // Sort descending
    std.mem.sort(i32, result.items, {}, comptime struct {
        fn lt(_: void, a: i32, b: i32) bool { return a > b; }
    }.lt);

    // Take top K
    const take = @min(k, result.items.len);
    const slice = try allocator.alloc(i32, take);
    @memcpy(slice, result.items[0..take]);
    // Note: std.ArrayList.deinit needs allocator in Zig 0.16
    return slice;
}
