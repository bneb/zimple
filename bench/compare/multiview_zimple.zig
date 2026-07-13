// Multi-view analysis — Zimple
// Filter, split into 5 category views, transform each, keep all views alive.
const std = @import("std");
const zimple = @import("zimple");

pub const Record = struct { id: i32, category: u8, value: f64 };

const Valid = struct { pub fn call(_: @This(), r: Record) bool { return r.value >= 0; } };
const Cat = struct { cat: u8, pub fn call(self: @This(), r: Record) bool { return r.category == self.cat; } };
const Ok  = struct { pub fn call(_: @This(), r: Record) bool { return r.value <= 1000; } };
const AddSq = struct { pub fn call(_: @This(), a: f64, r: Record) f64 { return a + r.value * r.value; } };

pub fn analyze(allocator: std.mem.Allocator, records: []const Record) !struct {
    cat_a_sum: f64, cat_b_sum: f64, cat_c_sum: f64, cat_d_sum: f64, cat_e_sum: f64,
    overall_sum: f64,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Step 1: filter invalid (structural sharing — valid shares subtrees with original)
    const v = try zimple.Vector(Record).fromSlice(aa, records);
    const valid = try zimple.filterVec(v, Valid{}, aa);

    // Steps 2+3: lazy pipeline — one traversal per category, zero allocation
    // (no try needed, no defer — lazy chains don't allocate)
    const sum_a = zimple.lazy.init(valid).filter(Cat{ .cat = 0 }).filter(Ok{}).fold(f64, 0, AddSq{});
    const sum_b = zimple.lazy.init(valid).filter(Cat{ .cat = 1 }).filter(Ok{}).fold(f64, 0, AddSq{});
    const sum_c = zimple.lazy.init(valid).filter(Cat{ .cat = 2 }).filter(Ok{}).fold(f64, 0, AddSq{});
    const sum_d = zimple.lazy.init(valid).filter(Cat{ .cat = 3 }).filter(Ok{}).fold(f64, 0, AddSq{});
    const sum_e = zimple.lazy.init(valid).filter(Cat{ .cat = 4 }).filter(Ok{}).fold(f64, 0, AddSq{});

    // Step 4: overall sum from still-alive valid vector
    const overall_sum = zimple.lazy.init(valid).filter(Ok{}).fold(f64, 0, AddSq{});

    return .{ .cat_a_sum = sum_a, .cat_b_sum = sum_b, .cat_c_sum = sum_c,
        .cat_d_sum = sum_d, .cat_e_sum = sum_e, .overall_sum = overall_sum };
}
