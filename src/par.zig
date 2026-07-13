const std = @import("std");
const Atomic = std.atomic.Value;
const hamt = @import("hamt.zig");

pub const Task = struct {
    runFn: *const fn (task: *Task) void,

    pub fn run(self: *Task) void {
        self.runFn(self);
    }
};

pub const SpinLock = struct {
    state: Atomic(bool) = Atomic(bool).init(false),
    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const WaitGroup = struct {
    count: Atomic(usize) = Atomic(usize).init(0),
    pub fn start(self: *WaitGroup) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }
    pub fn finish(self: *WaitGroup) void {
        _ = self.count.fetchSub(1, .release);
    }
    pub fn wait(self: *WaitGroup) void {
        if (current_worker) |w| {
            var prng = std.Random.DefaultPrng.init(@intFromPtr(w));
            while (self.count.load(.acquire) > 0) {
                if (w.deque.pop()) |t| {
                    t.run();
                } else if (w.pool.stealGlobal()) |t| {
                    t.run();
                } else if (w.pool.workers.len > 1) {
                    const victim_idx = prng.random().intRangeLessThan(usize, 0, w.pool.workers.len);
                    if (w.pool.workers[victim_idx].deque.steal()) |t| {
                        t.run();
                    } else {
                        std.atomic.spinLoopHint();
                    }
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        } else {
            while (self.count.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }
        }
    }
};

pub const Condition = struct {
    notifs: Atomic(usize) = Atomic(usize).init(0),
    pub fn wait(self: *Condition, m: *SpinLock) void {
        const start_val = self.notifs.load(.acquire);
        m.unlock();
        while (self.notifs.load(.acquire) == start_val) {
            std.atomic.spinLoopHint();
        }
        m.lock();
    }
    pub fn signal(self: *Condition) void {
        _ = self.notifs.fetchAdd(1, .release);
    }
    pub fn broadcast(self: *Condition) void {
        _ = self.notifs.fetchAdd(1, .release);
    }
};

pub const Executor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        submit: *const fn (ptr: *anyopaque, task: *Task) void,
    };

    pub fn submit(self: Executor, task: *Task) void {
        self.vtable.submit(self.ptr, task);
    }
};

/// A lock-free Chase-Lev work-stealing deque. Single producer, multi-consumer.
pub fn ChaseLevDeque(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        top: Atomic(usize) = Atomic(usize).init(0),
        bottom: Atomic(usize) = Atomic(usize).init(0),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{ .items = try allocator.alloc(T, capacity) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        pub fn push(self: *Self, item: T) !void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b -% t >= self.items.len) return error.QueueFull;
            self.items[b % self.items.len] = item;
            self.bottom.store(b +% 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic);
            if (b == 0) return null;
            const b_new = b -% 1;
            self.bottom.store(b_new, .monotonic);

            const t = self.top.load(.monotonic);
            if (b_new < t) {
                self.bottom.store(t, .release);
                return null;
            }
            const item = self.items[b_new % self.items.len];
            if (b_new > t) return item;

            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) == null) {
                self.bottom.store(t +% 1, .release);
                return item;
            } else {
                self.bottom.store(t +% 1, .release);
                return null;
            }
        }

        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            if (t >= b) return null;
            const item = self.items[t % self.items.len];
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) == null) {
                return item;
            } else {
                return null;
            }
        }
    };
}

threadlocal var current_worker: ?*ThreadPoolExecutor.Worker = null;

pub const ThreadPoolExecutor = struct {
    pub const Worker = struct {
        pool: *ThreadPoolExecutor,
        thread: std.Thread = undefined,
        deque: ChaseLevDeque(*Task),
        seed: u64,

        fn loop(self: *Worker) void {
            current_worker = self;
            var prng = std.Random.DefaultPrng.init(self.seed);
            const rand = prng.random();

            while (!self.pool.stop.load(.acquire)) {
                if (self.deque.pop()) |t| {
                    t.run();
                    continue;
                }

                if (self.pool.stealGlobal()) |t| {
                    t.run();
                    continue;
                }

                if (self.pool.workers.len > 1) {
                    const victim_idx = rand.intRangeLessThan(usize, 0, self.pool.workers.len);
                    if (self.pool.workers[victim_idx].deque.steal()) |t| {
                        t.run();
                        continue;
                    }
                }

                self.pool.global_queue.lock();
                if (self.pool.stop.load(.acquire)) {
                    self.pool.global_queue.unlock();
                    break;
                }
                if (self.pool.global_tasks.items.len == 0) {
                    self.pool.global_cond.wait(&self.pool.global_queue);
                }
                self.pool.global_queue.unlock();
            }
        }
    };

    allocator: std.mem.Allocator,
    workers: []Worker,
    stop: Atomic(bool) = Atomic(bool).init(false),
    global_cond: Condition = .{},
    global_queue: SpinLock = .{},
    global_tasks: std.ArrayListUnmanaged(*Task) = .empty,

    pub fn init(allocator: std.mem.Allocator, num_threads: usize) !*ThreadPoolExecutor {
        const self = try allocator.create(ThreadPoolExecutor);
        self.* = .{
            .allocator = allocator,
            .workers = try allocator.alloc(Worker, num_threads),
        };

        for (self.workers, 0..) |*w, i| {
            w.* = .{
                .pool = self,
                .deque = try ChaseLevDeque(*Task).init(allocator, 1024),
                .seed = @as(u64, @intCast(i)) * 123456789 + 1,
            };
        }
        for (self.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, Worker.loop, .{w});
        }
        return self;
    }

    pub fn deinit(self: *ThreadPoolExecutor) void {
        self.stop.store(true, .release);
        self.global_cond.broadcast();

        for (self.workers) |*w| {
            w.thread.join();
            w.deque.deinit(self.allocator);
        }
        self.allocator.free(self.workers);
        self.global_tasks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn executor(self: *ThreadPoolExecutor) Executor {
        return .{
            .ptr = self,
            .vtable = &.{ .submit = submitImpl },
        };
    }

    fn submitImpl(ptr: *anyopaque, task: *Task) void {
        const self: *ThreadPoolExecutor = @ptrCast(@alignCast(ptr));
        if (current_worker) |w| {
            if (w.deque.push(task)) {
                self.global_cond.signal();
                return;
            } else |_| {}
        }
        self.global_queue.lock();
        self.global_tasks.append(self.allocator, task) catch @panic("OOM");
        self.global_queue.unlock();
        self.global_cond.signal();
    }

    fn stealGlobal(self: *ThreadPoolExecutor) ?*Task {
        if (self.global_tasks.items.len == 0) return null;
        self.global_queue.lock();
        defer self.global_queue.unlock();
        if (self.global_tasks.items.len > 0) {
            return self.global_tasks.pop();
        }
        return null;
    }
};

// ---------------------------------------------------------
// parReduce
// ---------------------------------------------------------

pub fn parReduce(
    comptime K: type,
    comptime V: type,
    comptime ctx: hamt.HashContext(K),
    comptime R: type,
    exec: Executor,
    root: ?*const hamt.HashMap(K, V, ctx).Node,
    reduce_fn: *const fn (K, V) R,
    merge_fn: *const fn (R, R) R,
    identity: R,
) !R {
    if (root == null) return identity;

    const ReduceTask = struct {
        task: Task,
        node: *const hamt.HashMap(K, V, ctx).Node,
        result: R,
        wg: *WaitGroup,
        reduce_fn: *const fn (K, V) R,
        merge_fn: *const fn (R, R) R,
        identity: R,
        exec: Executor,
        depth: usize,

        fn run(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.result = reduceRecursive(self.node, self.reduce_fn, self.merge_fn, self.identity, self.exec, self.depth + 1) catch self.identity;
            self.wg.finish();
        }

        fn reduceRecursive(
            node: *const hamt.HashMap(K, V, ctx).Node,
            r_fn: *const fn (K, V) R,
            m_fn: *const fn (R, R) R,
            id: R,
            x: Executor,
            depth: usize,
        ) !R {
            switch (node.*) {
                .leaf => |*leaf| {
                    var sum = id;
                    for (leaf.values, 0..) |v, i| {
                        if (leaf.bitmap & (@as(u32, 1) << @intCast(i)) != 0) {
                            sum = m_fn(sum, r_fn(leaf.keys[i], v));
                        }
                    }
                    return sum;
                },
                .internal => |*internal| {
                    if (depth >= 2) {
                        // Adaptive Chunking: At depth 2 (or lower), compute sequentially
                        var sum = id;
                        for (internal.slots) |child_opt| {
                            if (child_opt) |child| {
                                sum = m_fn(sum, try reduceRecursive(child, r_fn, m_fn, id, x, depth + 1));
                            }
                        }
                        return sum;
                    }

                    var wg = WaitGroup{};
                    var tasks: [32]@This() = undefined;
                    var count: usize = 0;

                    for (internal.slots) |child_opt| {
                        if (child_opt) |child| {
                            tasks[count] = .{
                                .task = .{ .runFn = run },
                                .node = child,
                                .result = id,
                                .wg = &wg,
                                .reduce_fn = r_fn,
                                .merge_fn = m_fn,
                                .identity = id,
                                .exec = x,
                                .depth = depth,
                            };
                            wg.start();
                            x.submit(&tasks[count].task);
                            count += 1;
                        }
                    }

                    wg.wait();

                    var sum = id;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        sum = m_fn(sum, tasks[i].result);
                    }
                    return sum;
                },
            }
        }
    };

    return try ReduceTask.reduceRecursive(root.?, reduce_fn, merge_fn, identity, exec, 0);
}

// ---------------------------------------------------------
// parMap
// ---------------------------------------------------------

pub fn parMap(
    comptime K: type,
    comptime V: type,
    comptime ctx: hamt.HashContext(K),
    comptime V2: type,
    allocator: std.mem.Allocator,
    exec: Executor,
    root: ?*const hamt.HashMap(K, V, ctx).Node,
    map_fn: *const fn (K, V) V2,
) !hamt.HashMap(K, V2, ctx) {
    if (root == null) return hamt.HashMap(K, V2, ctx).empty(allocator);

    const OutMap = hamt.HashMap(K, V2, ctx);
    const NodeIn = hamt.HashMap(K, V, ctx).Node;
    const NodeOut = OutMap.Node;
    
    // We need an internal map function that returns a NodeOut
    const MapTask = struct {
        task: Task,
        node: *const NodeIn,
        result: ?*const NodeOut,
        err: ?std.mem.Allocator.Error,
        wg: *WaitGroup,
        map_fn: *const fn (K, V) V2,
        allocator: std.mem.Allocator,
        exec: Executor,

        depth: usize,

        fn mapRecursive(alloc: std.mem.Allocator, n: *const NodeIn, m_fn: *const fn (K, V) V2, x: Executor, depth: usize) std.mem.Allocator.Error!*const NodeOut {
            switch (n.*) {
                .leaf => |*leaf| {
                    const nr = try alloc.create(NodeOut);
                    var keys: [32]K = undefined;
                    var values: [32]V2 = undefined;
                    @memcpy(&keys, &leaf.keys);
                    for (leaf.values, 0..) |v, i| {
                        if (leaf.bitmap & (@as(u32, 1) << @intCast(i)) != 0) {
                            values[i] = m_fn(keys[i], v);
                        }
                    }
                    nr.* = .{ .leaf = .{ .bitmap = leaf.bitmap, .keys = keys, .values = values } };
                    return nr;
                },
                .internal => |*internal| {
                    if (depth >= 2) {
                        // Adaptive chunking: map sequentially
                        const nr = try alloc.create(NodeOut);
                        var slots: [32]?*const NodeOut = [_]?*const NodeOut{null} ** 32;
                        var slot_idx: usize = 0;
                        for (internal.slots) |child_opt| {
                            if (child_opt) |child| {
                                slots[slot_idx] = try mapRecursive(alloc, child, m_fn, x, depth + 1);
                            }
                            slot_idx += 1;
                        }
                        nr.* = .{ .internal = .{ .bitmap = internal.bitmap, .slots = slots } };
                        return nr;
                    }

                    var wg = WaitGroup{};
                    var tasks: [32]@This() = undefined;
                    var count: usize = 0;
                    for (internal.slots) |child_opt| {
                        if (child_opt) |child| {
                            tasks[count] = .{
                                .task = .{ .runFn = @This().run },
                                .node = child,
                                .result = null,
                                .err = null,
                                .wg = &wg,
                                .map_fn = m_fn,
                                .allocator = alloc,
                                .exec = x,
                                .depth = depth,
                            };
                            wg.start();
                            x.submit(&tasks[count].task);
                            count += 1;
                        }
                    }
                    wg.wait();
                    
                    const nr = try alloc.create(NodeOut);
                    var slots: [32]?*const NodeOut = [_]?*const NodeOut{null} ** 32;
                    var i: usize = 0;
                    var slot_idx: usize = 0;
                    for (internal.slots) |child_opt| {
                        if (child_opt != null) {
                            if (tasks[i].err) |e| return e;
                            slots[slot_idx] = tasks[i].result;
                            i += 1;
                        }
                        slot_idx += 1;
                    }
                    nr.* = .{ .internal = .{ .bitmap = internal.bitmap, .slots = slots } };
                    return nr;
                },
            }
        }


        fn run(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.result = mapRecursive(self.allocator, self.node, self.map_fn, self.exec, self.depth + 1) catch |err| b: {
                self.err = err;
                break :b null;
            };
            self.wg.finish();
        }
    };

    // Run the root task synchronously
    const out_root = try MapTask.mapRecursive(allocator, root.?, map_fn, exec, 0);

    // We need to count elements? The count is identical.
    // Wait, the original HashMap doesn't store count in the node.
    // But how do we know the count? We can just do a sequential count?
    // Oh, the map structure is identical, so count is identical!
    
    // Since we don't have the original count in parMap signature easily (only root),
    // wait, we can just compute count from the root by traversing it, or
    // we can change `parMap` to take the original map and return the new map.
    // Let's just traverse it to get the count, or change `parMap` to return just the root.
    // Actually, `OutMap.empty(allocator)` sets count=0. We can just set count=0 for now,
    // or we can compute it.
    // Let's compute it.
    const root_node = out_root;
    var out_map = OutMap.empty(allocator);
    out_map.root = root_node;
    
    // To set count, we can do a reduce over the output.
    const CountRed = struct {
        fn red(k: K, v: V2) usize { _ = k; _ = v; return 1; }
        fn merge(a: usize, b: usize) usize { return a + b; }
    };
    out_map.count = try parReduce(K, V2, ctx, usize, exec, root_node, CountRed.red, CountRed.merge, 0);

    return out_map;
}
