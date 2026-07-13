// Persistent TODO — demonstrates structural sharing for free undo/redo.
//
// Key insight: every mutation creates a new persistent Vector. Old states
// are kept alive by the history list at zero copy cost — unchanged
// subtrees are shared. Undo just pops the history list.
//
// Build: zig build-exe examples/todo.zig --dep zimple -Mzimple=src/root.zig
// Run:   ./zig-out/bin/todo

const std = @import("std");
const zimple = @import("zimple");

const Task = []const u8;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = App.init(alloc);
    defer app.deinit();

    // Demo scenario — shows all operations
    try print("--- Persistent TODO (undo/redo via structural sharing) ---\n\n", .{});

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

    try print("\nUndo stack shows 2 past states. Each state is a full persistent\n", .{});
    try print("vector — no copying, no checkpointing, just structural sharing.\n\n", .{});
}

const App = struct {
    alloc: std.mem.Allocator,
    items: zimple.Vector(Task),
    past: zimple.List(zimple.Vector(Task)),
    future: zimple.List(zimple.Vector(Task)),

    fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .alloc = alloc,
            .items = zimple.Vector(Task).empty(alloc),
            .past = zimple.List(zimple.Vector(Task)).empty(alloc),
            .future = zimple.List(zimple.Vector(Task)).empty(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.items.deinit();
        var cur = self.past;
        while (cur.head()) |_| { const state = cur.head().?; state.deinit(); cur = cur.tail().?; }
        self.past.deinit();
        cur = self.future;
        while (cur.head()) |_| { const state = cur.head().?; state.deinit(); cur = cur.tail().?; }
        self.future.deinit();
    }

    fn save(self: *@This()) !void {
        self.past = try self.past.cons(self.items);
        var cur = self.future;
        while (cur.head()) |_| { const state = cur.head().?; state.deinit(); cur = cur.tail().?; }
        self.future.deinit();
        self.future = zimple.List(zimple.Vector(Task)).empty(self.alloc);
    }

    fn add(self: *@This(), task: []const u8) !void {
        try self.save();
        self.items = try self.items.pushBack(task);
        try print("  added: {s}\n", .{task});
    }

    fn done(self: *@This(), id: usize) !void {
        if (id == 0 or id > self.items.len()) return;
        try self.save();
        const alloc = self.alloc;
        var buf = try alloc.alloc(Task, self.items.len() - 1);
        var it = self.items.iterator();
        var i: usize = 0;
        var idx: usize = 1;
        while (it.next()) |t| : (idx += 1) { if (idx != id) { buf[i] = t; i += 1; } }
        self.items = try zimple.Vector(Task).fromSlice(alloc, buf);
        alloc.free(buf);
    }

    fn undo(self: *@This()) !void {
        const prev = self.past.head() orelse return;
        self.future = try self.future.cons(self.items);
        self.items = prev;
        self.past = self.past.tail().?;
    }

    fn redo(self: *@This()) !void {
        const next = self.future.head() orelse return;
        self.past = try self.past.cons(self.items);
        self.items = next;
        self.future = self.future.tail().?;
    }

    fn list(self: *@This()) !void {
        try print("  tasks ({d}):\n", .{self.items.len()});
        if (self.items.len() == 0) { try print("    (empty)\n", .{}); return; }
        var it = self.items.iterator();
        var id: usize = 1;
        while (it.next()) |t| : (id += 1) { try print("    {d}. {s}\n", .{ id, t }); }
    }

    fn history(self: *@This()) !void {
        var n: usize = 0; var c = self.past; while (c.head()) |_| { n += 1; c = c.tail().?; }
        var f: usize = 0; c = self.future; while (c.head()) |_| { f += 1; c = c.tail().?; }
        try print("  state: {d} undo back, {d} redo forward\n", .{ n, f });
    }
};

fn print(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}
