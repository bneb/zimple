# Benchmarks

Three comparisons. Each tests a different claim.

## 1. Persistent Vector Build

500,000 push_backs. 16,131 nodes. 4.3 MB. ReleaseFast.

```
$ zig build benchmark
$ ocamlopt -O3 -o ocaml_bench unix.cmxa bench/ocaml_baseline.ml && ./ocaml_bench
```

| Metric | Zig Arena | Zig Direct | OCaml GC |
|--------|-----------|------------|----------|
| Build | 65.1 ms | 3432.4 ms | 40 ms |
| Teardown | 6.5 ms | 63.1 ms | 2.1 ms |
| Total | 71.6 ms | 3495.5 ms | 42 ms |

OCaml wins. Its GC is built for this pattern of many small, short-lived immutable nodes. It has been optimized for this since 1996.

Zig has no GC. Arena allocation bridges the gap. It is 50x faster than per-node mmap, and requires no runtime.

## 2. Particle Simulation

1,000,000 particles. 60 frames. Fused filter → map → reduce pipeline.

```
$ zig build particle
$ ocamlopt -O3 -o ocaml_particle unix.cmxa bench/ocaml_particle.ml && ./ocaml_particle
```

| Metric | Zig | OCaml |
|--------|-----|-------|
| Avg frame | 7.0 ms | 7.5 ms |
| Max frame | 9.2 ms | 8.6 ms |
| Dropped | 0/60 | 0/60 |
| Memory | 38 MB | ~120 MB |
| Particle size | 40 B | ~80 B |
| Pipeline | Fused | Separate |
| GC pauses | None | <1 µs |

Throughput is comparable. Zig wins memory 3x via unboxed structs in leaf arrays. OCaml has tighter variance. Both hit 60 fps. (Note: Frame times reflect steady-state hot cache performance for both).

The GC pause argument is weak for this workload. OCaml minor GC pauses are sub-microsecond. The arena advantage is memory density, not jitter.

## 3. Lisp Interpreter

Same interpreter. Two idioms. Raw Zig vs Zimple primitives.

```
$ zig build lisp
```

| Program | Zig (µs) | Zimple (µs) | Ratio |
|---------|----------|-------------|-------|
| fib-20 | 3805.7 | 3748.4 | 0.98x |
| ack-3-3 | 797.9 | 997.1 | 1.25x |
| sum-range | 154.0 | 126.9 | 0.82x |
| map-square | 126.5 | 126.5 | 1.00x |
| let-scope | 5.1 | 40.4 | 7.95x |
| lambda-capture | 7.0 | 30.7 | 4.38x

6/6 correctness. 37-line delta. Zimple closures compile to comparable code on the hot path. The effect is real but incremental. Zig native primitives handle most of the job.

## What this proves

OCaml is faster at building persistent data structures. The OCaml GC is purpose-built for this allocation pattern. Zig wins on memory density. Unboxed structs in leaf arrays use 3x less memory. Throughput is comparable once the iterator is optimized.

Arena allocation gives you persistent data structures with:
- No runtime dependency
- No GC pauses during computation
- 3x better memory density than a boxed FP language
- O(pages) teardown instead of O(nodes)

OCaml native compilation has been tuned for this since before Zig existed. Zig is slower at allocation. It is faster at memory density. It needs no runtime.

## 4. HAMT AMAC Bulk Lookup

Comparing `std.AutoHashMap` against Zimple `HashMap` (HAMT) for 100,000 lookups.

```
$ zig build bench-hamt
```

| Benchmark | µs | Ratio |
|-----------|----------|-------|
| zig-get | 150.6 | 1.00x |
| zimple-get | 5397.1 | 35.84x |
| zimple-bulkGet (AMAC) | 1173.4 | 7.79x |

Standard scalar `get` traversal on a persistent HAMT suffers heavily from cache misses. Asynchronous Memory Access Chaining (AMAC) pipelines the lookups, resolving the structural latency. It cuts the lookup time by 4.6x compared to scalar traversal.

It remains slower than raw `std.AutoHashMap`, but it significantly mitigates the tree-walking penalty for read-heavy batch operations.
