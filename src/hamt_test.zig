const std = @import("std");
const hamt = @import("hamt.zig");
const testing = std.testing;

const I32Ctx = hamt.autoHash(i32);
const H = hamt.HashMap(i32, i32, I32Ctx);

test "HashMap: empty and len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = H.empty(arena.allocator());
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.len());
    try testing.expect(m.isEmpty());
}

test "HashMap: put and get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 100);
    const m3 = try m2.put(2, 200);
    const m4 = try m3.put(3, 300);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();
    defer m4.deinit();

    try testing.expectEqual(@as(usize, 3), m4.len());
    try testing.expectEqual(@as(i32, 100), m4.get(1).?);
    try testing.expectEqual(@as(i32, 200), m4.get(2).?);
    try testing.expectEqual(@as(i32, 300), m4.get(3).?);
    try testing.expect(m4.get(99) == null);

    // Earlier versions still correct
    try testing.expectEqual(@as(usize, 1), m2.len());
    try testing.expectEqual(@as(i32, 100), m2.get(1).?);
}

test "HashMap: put replaces existing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 100);
    const m3 = try m2.put(1, 999);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();

    try testing.expectEqual(@as(usize, 1), m3.len());
    try testing.expectEqual(@as(i32, 999), m3.get(1).?);
}

test "HashMap: contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(42, 0);
    defer m1.deinit();
    defer m2.deinit();

    try testing.expect(m2.contains(42));
    try testing.expect(!m2.contains(99));
}

test "HashMap: structural sharing — put returns new map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 100);
    const m3 = try m2.put(2, 200);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();

    try testing.expectEqual(@as(usize, 1), m2.len());
    try testing.expectEqual(@as(i32, 100), m2.get(1).?);

    try testing.expectEqual(@as(usize, 2), m3.len());
    try testing.expectEqual(@as(i32, 100), m3.get(1).?);
    try testing.expectEqual(@as(i32, 200), m3.get(2).?);
}

test "HashMap: remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 100);
    const m3 = try m2.put(2, 200);
    const m4 = try m3.put(3, 300);
    const m5 = try m4.remove(2);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();
    defer m4.deinit();
    defer m5.deinit();

    try testing.expectEqual(@as(usize, 2), m5.len());
    try testing.expect(m5.contains(1));
    try testing.expect(!m5.contains(2));
    try testing.expect(m5.contains(3));

    // m4 unchanged
    try testing.expectEqual(@as(usize, 3), m4.len());
    try testing.expect(m4.contains(2));
}

test "HashMap: remove non-existent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 100);
    defer m1.deinit();
    defer m2.deinit();
    try testing.expectError(error.KeyNotFound, m2.remove(99));
}

test "HashMap: fromSlice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = [_]H.Entry{
        .{ .key = 1, .value = 10 },
        .{ .key = 2, .value = 20 },
        .{ .key = 3, .value = 30 },
    };
    const m = try H.fromSlice(arena.allocator(), &entries);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 3), m.len());
    try testing.expectEqual(@as(i32, 20), m.get(2).?);
}

test "HashMap: large — many insertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = H.empty(arena.allocator());
    defer m.deinit();

    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        m = try m.put(i, i * 10);
    }
    try testing.expectEqual(@as(usize, 1000), m.len());
    try testing.expectEqual(@as(i32, 5000), m.get(500).?);
    try testing.expectEqual(@as(i32, 9990), m.get(999).?);
    try testing.expect(m.get(1000) == null);
}

test "HashMap: string keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const StrCtx = hamt.HashContext([]const u8){
        .hash = struct {
            fn h(s: []const u8) u64 { return std.hash.Wyhash.hash(0, s); }
        }.h,
        .eql = struct {
            fn e(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
        }.e,
    };
    const SH = hamt.HashMap([]const u8, i32, StrCtx);

    const m1 = SH.empty(arena.allocator());
    const m2 = try m1.put("alice", 1);
    const m3 = try m2.put("bob", 2);
    const m4 = try m3.put("charlie", 3);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();
    defer m4.deinit();

    try testing.expectEqual(@as(usize, 3), m4.len());
    try testing.expectEqual(@as(i32, 2), m4.get("bob").?);
    try testing.expect(m4.get("dave") == null);
}

test "HashMap: iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m1 = H.empty(arena.allocator());
    const m2 = try m1.put(1, 10);
    const m3 = try m2.put(2, 20);
    const m4 = try m3.put(3, 30);
    defer m1.deinit();
    defer m2.deinit();
    defer m3.deinit();
    defer m4.deinit();

    var count: usize = 0;
    var sum: i32 = 0;
    var it = m4.iterator();
    while (it.next()) |entry| {
        count += 1;
        sum += entry.value;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(i32, 60), sum);
}

test "HashMap: remove from large map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = H.empty(arena.allocator());
    defer m.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        m = try m.put(i, i * 10);
    }

    const m2 = try m.remove(50);
    // Note: m and m2 share structure — only deinit one of them.
    // We deinit m (the original), then verify m2 via raw access.
    // Actually, since m2 shares nodes with m, we just verify m2
    // and let m.deinit() free everything.

    try testing.expectEqual(@as(usize, 99), m2.len());
    try testing.expect(!m2.contains(50));
    try testing.expect(m.contains(50));
    try testing.expectEqual(@as(i32, 490), m2.get(49).?);
    try testing.expectEqual(@as(i32, 510), m2.get(51).?);
}

test "HashMap: cross-validate against AutoHashMap oracle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var zmap = H.empty(aa);
    defer zmap.deinit();
    var oracle = std.AutoHashMap(i32, i32).init(aa);
    defer oracle.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const key: i32 = rand.intRangeLessThan(i32, 0, 100);
        const op = rand.intRangeLessThan(u8, 0, 4);
        switch (op) {
            0, 1 => { // put
                const val: i32 = rand.int(i32);
                zmap = try zmap.put(key, val);
                try oracle.put(key, val);
            },
            2 => { // get
                const z = zmap.get(key);
                const o = oracle.get(key);
                try testing.expectEqual(o, z);
            },
            3 => { // remove
                zmap = zmap.remove(key) catch zmap; // may not exist
                _ = oracle.remove(key);
            },
            else => unreachable,
        }
    }

    // Verify full contents match
    var oracle_keys = std.AutoHashMap(i32, void).init(aa);
    defer oracle_keys.deinit();
    var oracle_count: usize = 0;
    var oit = oracle.iterator();
    while (oit.next()) |e| : (oracle_count += 1) {
        try oracle_keys.put(e.key_ptr.*, {});
    }

    var zcount: usize = 0;
    var extra: usize = 0;
    var zit = zmap.iterator();
    while (zit.next()) |zentry| : (zcount += 1) {
        if (!oracle_keys.contains(zentry.key)) {
            std.debug.print("  EXTRA: zimple has key {d}, oracle does not\n", .{zentry.key});
            extra += 1;
        }
    }

    var missing: usize = 0;
    var zit2 = zmap.iterator();
    var zkeys = std.AutoHashMap(i32, void).init(aa);
    defer zkeys.deinit();
    while (zit2.next()) |zentry| try zkeys.put(zentry.key, {});
    var oit2 = oracle.iterator();
    while (oit2.next()) |e| {
        if (!zkeys.contains(e.key_ptr.*)) {
            std.debug.print("  MISSING: oracle has key {d} → {d}, zimple does not\n", .{ e.key_ptr.*, e.value_ptr.* });
            missing += 1;
        }
    }

    if (zcount != oracle_count or extra > 0 or missing > 0) {
        std.debug.print("  counts: oracle={d} zimple={d} extra={d} missing={d}\n", .{ oracle_count, zcount, extra, missing });
    }
    try testing.expectEqual(oracle_count, zcount);
    var it = oracle.iterator();
    while (it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, zmap.get(entry.key_ptr.*).?);
    }
}

test "HashMap: empty iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = H.empty(arena.allocator());
    defer m.deinit();

    var it = m.iterator();
    try testing.expect(it.next() == null);
}
