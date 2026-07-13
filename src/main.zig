const std = @import("std");
const zimple = @import("zimple");

pub fn main() !void {
    std.debug.print("=== Zimple: Functional Programming in Zig ===\n\n", .{});

    // ── Demo: plain struct callables ──
    std.debug.print("── Callables ──\n", .{});
    const Doubler = struct {
        factor: i32,
        pub fn call(self: @This(), x: i32) i32 {
            return self.factor * x;
        }
    };
    const doubler = Doubler{ .factor = 10 };
    std.debug.print("  double(5) = {d}\n", .{doubler.call(5)});

    // ── Demo: persistent list ──
    std.debug.print("\n── Persistent Cons-List ──\n", .{});
    const L = zimple.List(i32);
    var list = L.empty(arena.allocator());
    list = try list.cons(30);
    list = try list.cons(20);
    list = try list.cons(10);
    defer list.deinit();

    std.debug.print("  list = ", .{});
    var lit = list.iterator();
    while (lit.next()) |elem| {
        std.debug.print("{d} ", .{elem});
    }
    std.debug.print("\n", .{});

    // ── Demo: persistent vector ──
    std.debug.print("\n── Persistent Vector (Bitmapped Trie) ──\n", .{});
    const V = zimple.Vector(i32);
    var vec = V.empty(arena.allocator());
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        vec = try vec.pushBack(@intCast(i));
    }
    defer vec.deinit();

    std.debug.print("  len = {d}, vec[50] = {d}\n", .{ vec.len(), vec.get(50).? });

    // ── Demo: pattern matching ──
    std.debug.print("\n── Pattern Matching ──\n", .{});
    const d = zimple.destructureList(list);
    switch (d) {
        .empty => std.debug.print("  list is empty\n", .{}),
        .cons => |c| std.debug.print("  head={d}, tail_len={d}\n", .{ c.head, c.tail.len() }),
    }

    // ── Demo: combinators (plain struct callables) ──
    std.debug.print("\n── Combinators (filter → map → reduce) ──\n", .{});

    const IsOdd = struct {
        pub fn call(_: @This(), x: i32) bool {
            return @mod(x, 2) != 0;
        }
    };
    const Square = struct {
        pub fn call(_: @This(), x: i32) i32 {
            return x * x;
        }
    };
    const Add = struct {
        pub fn call(_: @This(), acc: i32, x: i32) i32 {
            return acc + x;
        }
    };

    var vec2 = V.empty(arena.allocator());
    var j: usize = 0;
    while (j < 20) : (j += 1) {
        vec2 = try vec2.pushBack(@intCast(j));
    }
    defer vec2.deinit();

    const odd_vec = try zimple.filterVec(vec2, IsOdd{}, arena.allocator());
    defer odd_vec.deinit();
    const squared = try zimple.mapVec(i32, odd_vec, Square{}, arena.allocator());
    defer squared.deinit();
    const result = zimple.reduceVec(squared, Add{}, @as(i32, 0));

    std.debug.print("  sum of odd squares 1..19 = {d}\n", .{result});

    // ── Demo: arena execution ──
    std.debug.print("\n── Arena Pipeline ──\n", .{});
    const arena_result = zimple.withArena(usize, struct {
        fn run(allocator: std.mem.Allocator) usize {
            const VL = zimple.Vector(i32);
            var vv = VL.empty(allocator);
            var k: usize = 0;
            while (k < 10000) : (k += 1) {
                vv = vv.pushBack(@intCast(k)) catch unreachable;
            }
            return vv.len();
        }
    }.run);
    std.debug.print("  arena pipeline result: {d} elements (arena freed in O(1))\n", .{arena_result});
}
