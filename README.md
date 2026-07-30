# Zimple

Immutable data structures for Zig. Persistent. Structural sharing. Arena-friendly.

## Quick start

```zig
const zimple = @import("zimple");

// Persistent vector — O(log₃₂ N) access, structural sharing
const V = zimple.Vector(i32);
const v1 = try V.fromSlice(allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
const v2 = try v1.set(0, 99); // v1 unchanged, subtrees shared

// HashMap — HAMT, same structural sharing model
const H = zimple.HashMap(i32, i32, zimple.autoHash(i32));
var m = H.empty(allocator);
defer m.deinit();
const m2 = try m.put(1, 100); // m unchanged, m2 shares subtrees

// Lazy chains — zero intermediate allocations
const IsOdd = struct { pub fn call(_: @This(), x: i32) bool { return @mod(x, 2) != 0; } };
const Sq    = struct { pub fn call(_: @This(), x: i32) i32  { return x * x; } };
const Add   = struct { pub fn call(_: @This(), a: i32, b: i32) i32 { return a + b; } };

const sum = zimple.lazy.init(v1).filter(IsOdd{}).map(i32, Sq{}).fold(i32, 0, Add{});
// sum = 1² + 3² + 5² + 7² + 9² = 165 — single pass, no allocations

// Option/Result — chainable, exhaustive matching
const s = zimple.some(@as(i32, 42));
const doubled = s.map(Sq{}); // some(1764)
switch (s.destructure()) { .some => |v| ..., .none => ... }

// Arena — allocate everything, free in one call
const result = zimple.withArena(usize, struct {
    fn run(a: std.mem.Allocator) usize {
        var v = zimple.Vector(i32).empty(a);
        for (0..10000) |i| v = v.pushBack(@intCast(i)) catch unreachable;
        return v.len();
    }
}.run);
// Arena freed — all 10k nodes reclaimed at once
```

## Why

Raw Zig handles mutable data well. `std.ArrayList` and `for` loops are fast and
concise. Zimple is for when you need immutable data:

- **Structural sharing.** New versions share unchanged subtrees. No full copies.
- **Arena-friendly.** Allocate everything in one arena, free in one call.
- **Lazy chains.** Filter, map, fold in one pass. No intermediate vectors.

Persistent structures share nodes across versions. Tracking lifetimes with
individual `defer` calls is error-prone (double-frees, use-after-free). An
arena avoids this — allocate everything together, free everything together.

For simple algorithms on mutable arrays, use `std.ArrayList`. For batch
transformations on persistent data, Zimple avoids the per-version copy and
defer cycles.

## Benchmarks

`zig build compare` reports LOC; `zig build compare-perf` reports time.

| Benchmark | Raw Zig | Zimple | What it avoids |
|-----------|---------|--------|-----------------|
| Versioned pipeline | 34 loc | 30 loc (−12%) | Per-version copy/defer |
| Multiview analysis | 71 loc | 38 loc (−46%) | Per-category alloc/defer |

Performance: Zimple is 8–23× slower on these benchmarks (`page_allocator`).
The gap is structural — tree walking vs flat arrays. Persistent structures
trade time for immutability.

See [BENCHMARKS.md](BENCHMARKS.md) for OCaml comparisons and allocator analysis.

## Modules

```
src/
├── vector.zig     Persistent bitmapped trie
├── hamt.zig       Persistent HashMap (HAMT)
├── hashset.zig    Persistent HashSet
├── queue.zig      Persistent two-list queue
├── list.zig       Persistent cons-list
├── lazy.zig       Chainable zero-alloc pipeline
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
