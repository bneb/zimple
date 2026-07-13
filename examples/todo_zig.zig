// Persistent TODO — raw Zig (no Zimple)
// Manual array copies and explicit checkpoint tracking for undo/redo.
const std = @import("std");

const Task = []const u8;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = App.init(alloc);
    defer app.deinit();

    try print("--- Persistent TODO (manual checkpointing) ---\n\n", .{});

    try app.add("buy milk");
    try app.add("call dentist");
    try app.add("finish report");
    try app.list();
    try app.history();

    try print("\n  > done 2\n", .{});
    try app.done(2);
    try app.list();

    try print("\n  > undo\n", .{});
    try app.undo();
    try app.list();

    try print("\n  > redo\n", .{});
    try app.redo();
    try app.list();

    try print("\n  > add \"reply to emails\"\n", .{});
    try app.add("reply to emails");
    try app.list();
    try app.history();
}

const Snapshot = struct { items: []const Task, len: usize };

const App = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Task),          // current task list
    past: std.ArrayList(Snapshot),       // undo stack (copies!)
    future: std.ArrayList(Snapshot),     // redo stack (copies!)

    fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .alloc = alloc,
            .items = std.ArrayList(Task).initCapacity(alloc, 0) catch @panic("OOM"),
            .past = std.ArrayList(Snapshot).initCapacity(alloc, 0) catch @panic("OOM"),
            .future = std.ArrayList(Snapshot).initCapacity(alloc, 0) catch @panic("OOM"),
        };
    }

    fn deinit(self: *@This()) void {
        // Free all snapshot copies
        for (self.past.items) |snap| self.alloc.free(snap.items);
        self.past.deinit(self.alloc);
        for (self.future.items) |snap| self.alloc.free(snap.items);
        self.future.deinit(self.alloc);
        self.items.deinit(self.alloc);
    }

    fn snapshot(self: *@This()) !Snapshot {
        const copy = try self.alloc.alloc(Task, self.items.items.len);
        @memcpy(copy, self.items.items);
        return .{ .items = copy, .len = self.items.items.len };
    }

    fn restore(self: *@This(), snap: Snapshot) !void {
        self.items.clearAndFree(self.alloc);
        try self.items.appendSlice(self.alloc, snap.items);
    }

    fn save(self: *@This()) !void {
        try self.past.append(self.alloc, try self.snapshot());
        // Free old future snapshots
        for (self.future.items) |snap| self.alloc.free(snap.items);
        self.future.clearRetainingCapacity();
    }

    fn add(self: *@This(), task: []const u8) !void {
        try self.save();
        try self.items.append(self.alloc, task);
        try print("  added: {s}\n", .{task});
    }

    fn done(self: *@This(), id: usize) !void {
        if (id == 0 or id > self.items.items.len) return;
        try self.save();
        _ = self.items.orderedRemove(id - 1);
    }

    fn undo(self: *@This()) !void {
        if (self.past.items.len == 0) return;
        try self.future.append(self.alloc, try self.snapshot());
        const prev = self.past.pop();
        try self.restore(prev);
        self.alloc.free(prev.items);
    }

    fn redo(self: *@This()) !void {
        if (self.future.items.len == 0) return;
        try self.past.append(self.alloc, try self.snapshot());
        const next = self.future.pop();
        try self.restore(next);
        self.alloc.free(next.items);
    }

    fn list(self: *@This()) !void {
        try print("  tasks ({d}):\n", .{self.items.items.len});
        if (self.items.items.len == 0) { try print("    (empty)\n", .{}); return; }
        for (self.items.items, 0..) |t, i| {
            try print("    {d}. {s}\n", .{ i + 1, t });
        }
    }

    fn history(self: *@This()) !void {
        try print("  state: {d} undo back, {d} redo forward\n", .{ self.past.items.len, self.future.items.len });
    }
};

fn print(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}
