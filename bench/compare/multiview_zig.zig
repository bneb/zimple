// Multi-view analysis — raw Zig
// Filter, split into 5 category views, transform each, keep all views alive.
const std = @import("std");

pub const Record = struct { id: i32, category: u8, value: f64 };

pub fn analyze(allocator: std.mem.Allocator, records: []const Record) !struct {
    cat_a_sum: f64, cat_b_sum: f64, cat_c_sum: f64, cat_d_sum: f64, cat_e_sum: f64,
    overall_sum: f64,
} {
    // Step 1: filter out invalid records (value < 0)
    var valid = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer valid.deinit(allocator);
    for (records) |r| if (r.value >= 0) try valid.append(allocator, r);

    // Step 2: split into categories A-E
    var cat_a = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer cat_a.deinit(allocator);
    var cat_b = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer cat_b.deinit(allocator);
    var cat_c = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer cat_c.deinit(allocator);
    var cat_d = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer cat_d.deinit(allocator);
    var cat_e = try std.ArrayList(Record).initCapacity(allocator, 0);
    defer cat_e.deinit(allocator);

    for (valid.items) |r| {
        switch (r.category) {
            0 => try cat_a.append(allocator, r),
            1 => try cat_b.append(allocator, r),
            2 => try cat_c.append(allocator, r),
            3 => try cat_d.append(allocator, r),
            4 => try cat_e.append(allocator, r),
            else => {},
        }
    }

    // Step 3: for each category — filter outliers (>1000), square values, sum
    var cat_a_sum: f64 = 0;
    for (cat_a.items) |r| {
        if (r.value <= 1000) cat_a_sum += r.value * r.value;
    }
    var cat_b_sum: f64 = 0;
    for (cat_b.items) |r| {
        if (r.value <= 1000) cat_b_sum += r.value * r.value;
    }
    var cat_c_sum: f64 = 0;
    for (cat_c.items) |r| {
        if (r.value <= 1000) cat_c_sum += r.value * r.value;
    }
    var cat_d_sum: f64 = 0;
    for (cat_d.items) |r| {
        if (r.value <= 1000) cat_d_sum += r.value * r.value;
    }
    var cat_e_sum: f64 = 0;
    for (cat_e.items) |r| {
        if (r.value <= 1000) cat_e_sum += r.value * r.value;
    }

    // Step 4: overall sum from the still-alive valid list
    var overall_sum: f64 = 0;
    for (valid.items) |r| {
        if (r.value <= 1000) overall_sum += r.value * r.value;
    }

    return .{
        .cat_a_sum = cat_a_sum, .cat_b_sum = cat_b_sum, .cat_c_sum = cat_c_sum,
        .cat_d_sum = cat_d_sum, .cat_e_sum = cat_e_sum, .overall_sum = overall_sum,
    };
}
