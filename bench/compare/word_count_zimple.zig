// Word count — Zimple
// Count word occurrences, return sorted by frequency descending.
const std = @import("std");
const zimple = @import("zimple");

const Entry = struct { word: []const u8, count: usize };

pub fn run(allocator: std.mem.Allocator, text: []const u8) ![]Entry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const StringCtx = zimple.HashContext([]const u8){
        .hash = struct {
            fn h(s: []const u8) u64 { return std.hash.Wyhash.hash(0, s); }
        }.h,
        .eql = struct {
            fn e(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
        }.e,
    };
    const H = zimple.HashMap([]const u8, usize, StringCtx);

    // Build frequency map
    var map = H.empty(aa);
    var word_start: ?usize = null;
    for (text, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            if (word_start == null) word_start = i;
        } else if (word_start) |start| {
            const word = text[start..i];
            const lowered = try aa.alloc(u8, word.len);
            for (word, 0..) |ch, j| lowered[j] = std.ascii.toLower(ch);
            const prev = map.get(lowered) orelse 0;
            map = try map.put(lowered, prev + 1);
            word_start = null;
        }
    }

    // Collect and sort
    var entries = try std.ArrayList(Entry).initCapacity(aa, 0);
    var it = map.iterator();
    while (it.next()) |kv| {
        try entries.append(aa, .{ .word = kv.key, .count = kv.value });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool { return a.count > b.count; }
    }.lt);

    return try entries.toOwnedSlice(aa);
}
