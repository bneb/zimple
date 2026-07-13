# Zimple

Immutable data structures for Zig. Persistent. Structural sharing. Arena-friendly.

## Quick start

```zig
const zimple = @import("zimple");

// Persistent vector: O(log32 N) access, structural sharing
const V = zimple.Vector(i32);
const v1 = try V.fromSlice(allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
const v2 = try v1.set(0, 99); // v1 unchanged, subtrees shared

// HashMap — HAMT, same structural sharing model
const H = zimple.HashMap(i32, i32, zimple.autoHash(i32));
var m = H.empty(allocator);
defer m.deinit();
const m2 = try m.put(1, 100); // m unchanged, m2 shares subtrees

// Lazy chains: zero intermediate allocations
const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
const Sq    = struct { pub fn call(_: @This(), x: i32) i32  { return x * x; } };
const Add   = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };

const sum = zimple.lazy.from(v1).filter(IsOdd{}).map(i32, Sq{}).fold(i32, 0, Add{});
// sum = 1² + 3² + 5² + 7² + 9² = 165: single pass, no allocations

// Option/Result — chainable, exhaustive matching
const s = zimple.some(@as(i32, 42));
const doubled = s.map(Sq{}); // some(1764)
switch (s.destructure()) { .some => |v| ..., .none => ... }

// Arena — allocate everything, free O(pages), zero leaks
const result = zimple.withArena(usize, struct {
    fn run(a: std.mem.Allocator) usize {
        var v = zimple.Vector(i32).empty(a);
        for (0..10000) |i| v = v.pushBack(@intCast(i)) catch unreachable;
        return v.len();
    }
}.run);
// Arena freed: all 10k nodes reclaimed at once
```

## Lifetime Management & Arenas

Persistent data structures in Zig require careful memory management. Because nodes are shared across versions, individual `defer m.deinit()` calls can cause double-frees or use-after-frees if multiple maps share structure.

Zimple embraces an **Arena-first** philosophy for persistent data. Instead of tracking lifetimes of individual nodes, allocate the entire structure in an `ArenaAllocator`. When finished with the structure, drop the arena. This frees all nodes in O(1) time without walking the tree.

For short-lived transformations, use `withArena` or `withArenaCopy` to scope the memory cleanly:
```zig
const final_vec = try zimple.withArenaCopy(i32, page_allocator, struct {
    fn run(arena: std.mem.Allocator) !zimple.Vector(i32) {
        // Intermediate versions share nodes, but we don't deinit them!
        var v = zimple.Vector(i32).empty(arena);
        for (0..100) |i| v = try v.pushBack(@intCast(i));
        return v; 
    }
}.run);
defer final_vec.deinit(); // Safely copies out of the arena
```

## Why

Raw Zig handles mutable data well. `std.ArrayList` and `for` loops are fast and concise. Zimple solves the problem of immutable data.

- **Structural sharing.** New versions share unchanged subtrees. No full copies.
- **Arena-friendly.** One arena, one free call, O(pages) teardown.
- **Lazy chains.** Filter, map, fold in one pass. No intermediate vectors.

Use `std.ArrayList` for simple algorithms on mutable arrays. Use Zimple for batch transformations on persistent data. It eliminates the per-version copy and defer cycles.

## Benchmarks

`zig build compare` reports LOC; `zig build compare-perf` reports time.

| Benchmark | Raw Zig | Zimple | What it avoids |
|-----------|---------|--------|-----------------|
| Versioned pipeline | 34 loc | 30 loc (−12%) | Arena + structural sharing eliminates per-version copy/defer |
| Multiview analysis | 71 loc | 38 loc (−46%) | Lazy chain + arena avoids per-category alloc/defer |

Performance: Zimple is 8-23x slower on these benchmarks using `page_allocator`. The gap is structural. Tree walking is slower than flat arrays. Persistent structures trade time for immutability.

See [BENCHMARKS.md](BENCHMARKS.md) for OCaml comparisons and allocator analysis.

## Callables

Zimple uses a type-erased "Callable" pattern for all functional transforms (`map`, `filter`, `reduce`). A `Callable` is any struct with a `.call(...)` method matching the expected arity.

Because Zig relies on `anytype` parameters, there is no heap allocation or virtual dispatch overhead.

```zig
const Square = struct {
    pub fn call(_: @This(), x: i32) i32 { return x * x; }
};
// Use it instantly with lazy pipelines or combinators:
const pipeline = zimple.lazy.from(vec).map(i32, Square{});
```

For file-scope functions that need environment capture without boilerplate, use `wrap`:
```zig
const Env = struct { multiplier: i32 };
fn scale(env: Env, x: i32) i32 { return env.multiplier * x; }
const c = zimple.fn_combinators.wrap(Env{ .multiplier = 10 }, scale);
```

## Modules

```
src/
├── vector.zig     Persistent bitmapped trie
├── hamt.zig       Persistent HashMap (HAMT)
├── hashset.zig    Persistent HashSet
├── queue.zig      Persistent two-list queue
├── list.zig       Persistent cons-list
├── lazy.zig       Generic Chainable zero-alloc pipeline
├── combinators.zig   map, filter, reduce, bind
├── maybe.zig      Option(T), Result(T, E)
├── pattern.zig    Comptime-exhaustive match
├── arena_exec.zig Scoped arena teardown
├── fn_combinators.zig compose, curry, wrap, memo
├── closure.zig    Typed closures
```

138 tests. Zero leaks.

## Build

```bash
zig build test          # 138 tests
zig build compare       # LOC comparison (2 benchmarks)
zig build compare-perf  # Performance comparison
```

Zig 0.16.0.
