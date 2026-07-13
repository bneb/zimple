pub const closure = @import("closure.zig");
pub const list = @import("list.zig");
pub const vector = @import("vector.zig");
pub const pattern = @import("pattern.zig");
pub const arena_exec = @import("arena_exec.zig");
pub const combinators = @import("combinators.zig");
pub const fn_combinators = @import("fn_combinators.zig");
pub const maybe = @import("maybe.zig");
pub const infer = @import("infer.zig");
pub const hamt = @import("hamt.zig");
pub const hashset = @import("hashset.zig");
pub const queue = @import("queue.zig");
pub const iter = @import("iter.zig");
pub const lazy = @import("lazy.zig");
pub const amac = @import("amac.zig");
pub const par = @import("par.zig");
pub const AmacEngine = amac.AmacEngine;
pub const ThreadPoolExecutor = par.ThreadPoolExecutor;
pub const parReduce = par.parReduce;
pub const parMap = par.parMap;

// ── Flat re-exports for ergonomic use ──

// HashMap
pub const HashMap = hamt.HashMap;
pub const HashContext = hamt.HashContext;
pub const autoHash = hamt.autoHash;
pub const HashSet = hashset.HashSet;
pub const Queue = queue.Queue;

// List
pub const List = list.List;

// Vector
pub const Vector = vector.Vector;

// Pipeline

// Algebraic types
pub const Option = maybe.Option;
pub const Result = maybe.Result;
pub const some = maybe.some;
pub const none = maybe.none;
pub const ok = maybe.ok;

// Pattern matching
pub const destructureList = pattern.destructureList;
pub const matchList = pattern.matchList;
pub const match2 = pattern.match2;

// Arena execution
pub const withArena = arena_exec.withArena;
pub const withArenaCopy = arena_exec.withArenaCopy;

// Combinators
pub const mapList = combinators.mapList;
pub const filterList = combinators.filterList;
pub const reduceList = combinators.reduceList;
pub const bindList = combinators.bindList;
pub const mapVec = combinators.mapVec;
pub const filterVec = combinators.filterVec;
pub const reduceVec = combinators.reduceVec;
pub const bindVec = combinators.bindVec;
pub const filterMapVec = maybe.filterMapVec;

// Function combinators
pub const compose = fn_combinators.compose;
pub const curry = fn_combinators.curry;
pub const memo = fn_combinators.memo;
pub const wrap = fn_combinators.wrap;

// Type-inferred wrappers (constructors in zimple.infer.* to avoid
// colliding with the module names)
pub const map = infer.map;
pub const filter = infer.filter;
pub const reduce = infer.reduce;
pub const bind = infer.bind;

test {
    _ = closure;
    _ = list;
    _ = vector;
    _ = @import("vector_test.zig");
    _ = pattern;
    _ = arena_exec;
    _ = combinators;
    _ = @import("combinators_test.zig");
    _ = fn_combinators;
    _ = maybe;
    _ = infer;
    _ = hamt;
    _ = hashset;
    _ = queue;
    _ = iter;
    _ = lazy;
    _ = amac;
    _ = par;
    _ = @import("simd_test.zig");
}
