(* OCaml baseline for Zimple benchmarks.
   Compares OCaml's GC against Zig's arena O(pages) teardown.
   Build: ocamlopt -O3 -o ocaml_bench unix.cmxa ocaml_baseline.ml
   Run:   ./ocaml_bench *)

let branch = 32
let bits = 5

type 'a node =
  | Internal of { mutable count : int; bitmap : int32; slots : 'a node option array }
  | Leaf of { mutable count : int; bitmap : int32; values : 'a array }

type 'a pvec = {
  root : 'a node option;
  size : int;
  shift : int;
}

let empty () = { root = None; size = 0; shift = 0 }

let alloc_leaf value =
  let values = Array.make branch value in
  Leaf { count = 1; bitmap = 1l; values }

let rec create_path shift index value =
  if shift = 0 then alloc_leaf value
  else begin
    let child_idx = (index lsr shift) land (branch - 1) in
    let child = create_path (shift - bits) index value in
    let slots = Array.make branch None in
    slots.(child_idx) <- Some child;
    Internal { count = 1; bitmap = Int32.shift_left 1l child_idx; slots }
  end

let rec push_back_rec alloc node shift index value =
  if shift = 0 then
    match node with
    | Leaf leaf ->
      if leaf.count < branch then begin
        let n = Leaf { count = leaf.count + 1; bitmap = Int32.logor leaf.bitmap (Int32.shift_left 1l leaf.count);
                       values = Array.copy leaf.values } in
        (match n with Leaf nl -> nl.values.(leaf.count) <- value | _ -> ());
        n
      end else begin
        let new_leaf = alloc_leaf value in
        let slots = Array.make branch None in
        slots.(0) <- Some node;
        slots.(1) <- Some new_leaf;
        Internal { count = 2; bitmap = 3l; slots }
      end
    | Internal _ -> failwith "shift=0 must be leaf"
  else
    match node with
    | Internal internal ->
      let child_idx = (index lsr shift) land (branch - 1) in
      let new_child =
        match internal.slots.(child_idx) with
        | Some child -> push_back_rec alloc child (shift - bits) index value
        | None -> create_path (shift - bits) index value
      in
      let slots = Array.copy internal.slots in
      slots.(child_idx) <- Some new_child;
      let bitmap = Int32.logor internal.bitmap (Int32.shift_left 1l child_idx) in
      let count = if internal.slots.(child_idx) = None then internal.count + 1 else internal.count in
      Internal { count; bitmap; slots }
    | Leaf _ -> failwith "shift>0 must be internal"

let push_back v value =
  match v.root with
  | None -> { root = Some (alloc_leaf value); size = 1; shift = 0 }
  | Some root ->
    let root, shift =
      if v.size = (1 lsl (v.shift + bits)) then begin
        let slots = Array.make branch None in
        slots.(0) <- Some root;
        (Internal { count = 1; bitmap = 1l; slots }, v.shift + bits)
      end else (root, v.shift)
    in
    let new_root = push_back_rec () root shift v.size value in
    { root = Some new_root; size = v.size + 1; shift }

let rec get_rec node shift index =
  match node with
  | Leaf leaf ->
    let idx = index land (branch - 1) in
    if idx < leaf.count then Some leaf.values.(idx) else None
  | Internal internal ->
    let idx = (index lsr shift) land (branch - 1) in
    match internal.slots.(idx) with
    | Some child -> get_rec child (shift - bits) index
    | None -> None

let get v index =
  if index >= v.size then None
  else match v.root with None -> None | Some root -> get_rec root v.shift index

let bench_build n =
  let v = ref (empty ()) in
  for i = 0 to n - 1 do
    v := push_back !v i
  done;
  !v

let time_ms f =
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  let ms = (t1 -. t0) *. 1000.0 in
  (result, ms)

let () =
  let n = 500_000 in
  let leaves = (n + 31) / 32 in
  let l1 = (leaves + 31) / 32 in
  let l2 = (l1 + 31) / 32 in
  let total_nodes = leaves + l1 + l2 + 1 in

  Printf.printf "=== OCaml GC Baseline ===\n";
  Printf.printf "OCaml 5.5.0\n";
  Printf.printf "N=%d, nodes=%d\n\n" n total_nodes;

  (* Warmup *)
  Gc.full_major ();
  Gc.full_major ();

  Printf.printf "── Build + GC Teardown ──\n";
  for round = 1 to 5 do
    Gc.full_major ();
    let v, build_ms = time_ms (fun () -> bench_build n) in
    let _ = v in
    let gc_ms_start = Unix.gettimeofday () in
    Gc.full_major ();
    let gc_ms = (Unix.gettimeofday () -. gc_ms_start) *. 1000.0 in
    Printf.printf "  Round %d: build=%.0fms  gc=%.2fms\n" round build_ms gc_ms
  done;

  Printf.printf "\n── Teardown Scaling ──\n";
  Printf.printf "  N          Nodes    GC(ms)\n";
  Printf.printf "  ────────   ──────   ──────\n";
  let sizes = [1000; 10000; 100000; 500000] in
  List.iter (fun ns ->
    let leaves = (ns + 31) / 32 in
    let l1 = (leaves + 31) / 32 in
    let nodes = leaves + l1 + (l1 + 31) / 32 + 1 in
    Gc.full_major ();
    Gc.full_major ();
    let v = bench_build ns in
    let t0 = Unix.gettimeofday () in
    Gc.full_major ();
    let dur = (Unix.gettimeofday () -. t0) *. 1000.0 in
    Printf.printf "  %-9d  %-6d   %.1f\n" ns nodes dur;
    ignore v
  ) sizes;

  (* Head-to-head *)
  Printf.printf "\n── Cross-Runtime Comparison (N=500,000, %d nodes) ──\n" total_nodes;
  Printf.printf "  ┌─────────────────────┬────────────┬──────────────┐\n";
  Printf.printf "  │ Metric              │ Zig Arena  │ OCaml GC     │\n";
  Printf.printf "  ├─────────────────────┼────────────┼──────────────┤\n";
  Printf.printf "  │ Allocation (build)  │   80.9 ms  │   (above)    │\n";
  Printf.printf "  │ Teardown            │    4.8 ms  │   (above)    │\n";
  Printf.printf "  │ Total               │   85.7 ms  │   (above)    │\n";
  Printf.printf "  └─────────────────────┴────────────┴──────────────┘\n";
  Printf.printf "\n";
  Printf.printf "  OCaml's GC is purpose-built for this allocation pattern:\n";
  Printf.printf "  many small, short-lived immutable objects. Arena's advantage\n";
  Printf.printf "  is the absence of GC pauses during computation and O(pages)\n";
  Printf.printf "  teardown vs O(live-set) tracing.\n"
