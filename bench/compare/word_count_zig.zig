// Word count — raw Zig
// Count word occurrences, return sorted by frequency descending.
const std = @import("std");

const Entry = struct { word: []const u8, count: usize };

pub fn run(allocator: std.mem.Allocator, text: []const u8) ![]Entry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build frequency map
    var map = std.StringHashMap(usize).init(aa);
    var word_start: ?usize = null;
    for (text, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            if (word_start == null) word_start = i;
        } else if (word_start) |start| {
            const word = text[start..i];
            const lowered = try aa.alloc(u8, word.len);
            for (word, 0..) |ch, j| lowered[j] = std.ascii.toLower(ch);
            const entry = try map.getOrPutValue(lowered, 0);
            entry.value_ptr.* += 1;
            word_start = null;
        }
    }

    // Collect into array
    var entries = try std.ArrayList(Entry).initCapacity(aa, 0);
    var it = map.iterator();
    while (it.next()) |kv| {
        try entries.append(aa, .{ .word = kv.key_ptr.*, .count = kv.value_ptr.* });
    }

    // Sort descending by count
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool { return a.count > b.count; }
    }.lt);

    return try entries.toOwnedSlice(aa);
}
