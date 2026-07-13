// Top-K — Zimple
// Keep positives, square them, sort descending, take top K.
const std = @import("std");
const zimple = @import("zimple");

pub fn topK(allocator: std.mem.Allocator, input: []const i32, k: usize) ![]i32 {
    const vec = try zimple.Vector(i32).fromSlice(allocator, input);
    defer vec.deinit();

    var p = zimple.infer.pipeline(vec);
    defer p.deinit();

    const Pos = struct {
        pub fn call(_: @This(), x: i32) bool { return x > 0; }
    };
    try p.filter(Pos{});

    const Sq = struct {
        pub fn call(_: @This(), x: i32) i32 { return x * x; }
    };
    try p.map(Sq{});

    const vs = p.collect();
    // Sort descending and take top K
    var items = try allocator.alloc(i32, vs.len());
    var it = vs.iterator();
    var idx: usize = 0;
    while (it.next()) |x| : (idx += 1) { items[idx] = x; }

    std.mem.sort(i32, items, {}, comptime struct {
        fn lt(_: void, a: i32, b: i32) bool { return a > b; }
    }.lt);

    const take = @min(k, items.len);
    const slice = try allocator.alloc(i32, take);
    @memcpy(slice, items[0..take]);
    allocator.free(items);
    return slice;
}
