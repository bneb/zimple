// Zimple vs Raw Zig — head-to-head LOC comparison
const std = @import("std");

fn countLines(comptime path: []const u8) usize {
    const src = @embedFile(path);
    var count: usize = 0;
    for (src) |c| {
        if (c == '\n') count += 1;
    }
    return if (src.len > 0 and src[src.len - 1] != '\n') count + 1 else count;
}

pub fn main() !void {
    const vz = countLines("versioned_zig.zig");
    const vm = countLines("versioned_zimple.zig");
    const mz = countLines("multiview_zig.zig");
    const mm = countLines("multiview_zimple.zig");

    std.debug.print("\n=== Zimple vs Raw Zig — LOC ===\n\n", .{});
    std.debug.print("  {s:<15} {s:>6} {s:>6} {s:>7}  {s}\n", .{ "benchmark", "zig", "zimple", "delta", "" });
    std.debug.print("  {s:-<15} {s:-<6} {s:-<6} {s:-<7}\n", .{ "", "", "", "" });

    const d1: isize = @as(isize, @intCast(vm)) - @as(isize, @intCast(vz));
    std.debug.print("  {s:<15} {d:>5}  {d:>5}   {s}{d}  ({s})\n", .{ "versioned", vz, vm, if (d1 < 0) "-" else "+", if (d1 < 0) -d1 else d1, "structural sharing + arena" });

    const d2: isize = @as(isize, @intCast(mm)) - @as(isize, @intCast(mz));
    std.debug.print("  {s:<15} {d:>5}  {d:>5}   {s}{d}  ({s})\n", .{ "multiview", mz, mm, if (d2 < 0) "-" else "+", if (d2 < 0) -d2 else d2, "lazy composition + arena" });

    std.debug.print("  {s:-<15} {s:-<6} {s:-<6} {s:-<7}\n", .{ "", "", "", "" });
    const tz = vz + mz;
    const tm = vm + mm;
    const td: isize = @as(isize, @intCast(tm)) - @as(isize, @intCast(tz));
    std.debug.print("  {s:<15} {d:>5}  {d:>5}   {s}{d}\n", .{ "total", tz, tm, if (td < 0) "-" else "+", if (td < 0) -td else td });

    std.debug.print("\n  Zimple is shorter on batch transformations of persistent data.\n", .{});
    std.debug.print("  Raw Zig is shorter on simple algorithms over mutable arrays.\n\n", .{});
}
