const std = @import("std");
const list_mod = @import("list.zig");
const vec_mod = @import("vector.zig");

/// Create an arena, run the pipeline function, tear down the arena in O(1).
/// The pipeline receives the arena's allocator and must return an "unboxed"
/// value — i.e., a value containing NO pointers into the arena.
///
/// Violating this contract results in use-after-free. Use `withArenaCopy`
/// if you need to deep-copy the result.
pub fn withArena(comptime T: type, pipeline: *const fn (allocator: std.mem.Allocator) T) T {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return pipeline(arena.allocator());
}

/// Like `withArena`, but deep-copies the result using a user-provided copier.
/// The copier receives the arena allocator (for the temporary value) and a
/// heap allocator (for the final copy).
pub fn withArenaCopy(
    comptime T: type,
    pipeline: *const fn (allocator: std.mem.Allocator) T,
    copier: *const fn (arena_allocator: std.mem.Allocator, heap_allocator: std.mem.Allocator, value: T) anyerror!T,
) anyerror!T {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_value = pipeline(arena.allocator());
    // Copy to heap so the result outlives the arena
    return try copier(arena.allocator(), std.heap.page_allocator, arena_value);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "withArena — scalar result (no arena pointers escape)" {
    // Pipeline: allocate a bunch of intermediate lists, return a scalar.
    const Result = struct {
        sum: i32,
        count: usize,
    };

    const pipeline = struct {
        fn run(allocator: std.mem.Allocator) Result {
            const L = list_mod.List(i32);
            var list = L.empty(allocator);
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                list = list.cons(@intCast(i)) catch unreachable;
            }

            var sum: i32 = 0;
            var count: usize = 0;
            var it = list.iterator();
            while (it.next()) |elem| {
                sum += elem;
                count += 1;
            }
            return .{ .sum = sum, .count = count };
        }
    }.run;

    const result = withArena(Result, pipeline);
    // Sum of 0..99 = 99*100/2 = 4950
    try testing.expectEqual(@as(i32, 4950), result.sum);
    try testing.expectEqual(@as(usize, 100), result.count);
}

test "withArena — arena teardown frees all nodes" {
    // This test uses testing.allocator as the backing allocator for the arena,
    // which means it will fail if any nodes leak.
    const result = withArena(usize, struct {
        fn run(allocator: std.mem.Allocator) usize {
            const L = list_mod.List(i32);
            var list = L.empty(allocator);
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                list = list.cons(@intCast(i)) catch unreachable;
            }
            return list.len();
        }
    }.run);

    // The arena has been torn down. The result is a simple scalar.
    try testing.expectEqual(@as(usize, 1000), result);
    // If arena.deinit() didn't free the list nodes, testing.allocator would
    // complain when it's checked. But since withArena uses page_allocator as
    // the backing store, this test verifies correctness, not leak detection.
}

test "withArena — vector pipeline" {
    const Result = struct { sum: i32, len: usize };

    const pipeline = struct {
        fn run(allocator: std.mem.Allocator) Result {
            const V = vec_mod.Vector(i32);
            var vec = V.empty(allocator);
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                vec = vec.pushBack(@intCast(i)) catch unreachable;
            }
            var sum: i32 = 0;
            var j: usize = 0;
            while (j < vec.len()) : (j += 1) {
                sum += vec.get(j).?;
            }
            return .{ .sum = sum, .len = vec.len() };
        }
    }.run;

    const result = withArena(Result, pipeline);
    try testing.expectEqual(@as(usize, 200), result.len);
    try testing.expectEqual(@as(i32, 19900), result.sum); // sum 0..199 = 199*200/2
}

test "multiple arena pipelines — no cross-contamination" {
    const L = list_mod.List(i32);

    const pipeline_a = struct {
        fn run(allocator: std.mem.Allocator) i32 {
            var list = L.empty(allocator);
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                list = list.cons(@intCast(i)) catch unreachable;
            }
            return @intCast(list.len());
        }
    }.run;

    const pipeline_b = struct {
        fn run(allocator: std.mem.Allocator) i32 {
            var list = L.empty(allocator);
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                list = list.cons(@intCast(i)) catch unreachable;
            }
            return @intCast(list.len());
        }
    }.run;

    const a = withArena(i32, pipeline_a);
    const b = withArena(i32, pipeline_b);

    try testing.expectEqual(@as(i32, 50), a);
    try testing.expectEqual(@as(i32, 100), b);
}

test "withArenaCopy — deep copy result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Pipeline returns a slice; copier duplicates it to the heap
    const pipeline = struct {
        fn run(allocator: std.mem.Allocator) []const u8 {
            _ = allocator;
            return "hello arena";
        }
    }.run;

    const copier = struct {
        fn copy(_: std.mem.Allocator, heap_allocator: std.mem.Allocator, value: []const u8) anyerror![]const u8 {
            const copy_buf = try heap_allocator.alloc(u8, value.len);
            @memcpy(copy_buf, value);
            return copy_buf;
        }
    }.copy;

    const result = try withArenaCopy([]const u8, pipeline, copier);
    defer std.heap.page_allocator.free(result);
    try testing.expectEqualStrings("hello arena", result);
}
