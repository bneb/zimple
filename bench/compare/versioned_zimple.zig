// Versioned pipeline — Zimple
// Build a vector, transform through 4 steps, keep ALL versions alive.
// Structural sharing: unchanged subtrees shared, not copied.
const std = @import("std");
const zimple = @import("zimple");

pub fn run(allocator: std.mem.Allocator, n: usize) !void {
    var a = std.heap.ArenaAllocator.init(allocator);
    defer a.deinit();
    const aa = a.allocator();

    // Build initial vector
    var v0 = try zimple.Vector(i32).fromSlice(aa, &.{});
    var j: usize = 0;
    while (j < n) : (j += 1) { v0 = try v0.pushBack(@intCast(j)); }

    const Odd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
    const Sq  = struct { pub fn call(_: @This(), x: i32) i32  { return x * x; } };
    const Gt  = struct { pub fn call(_: @This(), x: i32) bool { return x > 1000; } };
    const Dbl = struct { pub fn call(_: @This(), x: i32) i32  { return x * 2; } };

    // Each step shares structure with previous — no full copies
    const v1 = try zimple.filterVec(v0, Odd{}, aa);
    const v2 = try zimple.mapVec(i32, v1, Sq{}, aa);
    const v3 = try zimple.filterVec(v2, Gt{}, aa);
    const v4 = try zimple.mapVec(i32, v3, Dbl{}, aa);

    _ = .{ v0, v1, v2, v3, v4 };
    // Arena frees everything in O(pages) — no per-version deinit
}
