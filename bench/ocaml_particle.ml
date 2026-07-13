(* OCaml particle simulation — matches Zig particle_sim.zig.
   Compare: unboxed structs (Zig) vs boxed records (OCaml),
   GC pauses (OCaml) vs arena determinism (Zig).
   Build: ocamlopt -O3 -o ocaml_particle unix.cmxa ocaml_particle.ml *)

let branch = 32
let bits = 5

type vec2 = { x : float; y : float }

type particle = {
  pos : vec2;
  vel : vec2;
  alive : bool;
}

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

let rec push_back_rec node shift index value =
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
        | Some child -> push_back_rec child (shift - bits) index value
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
    let new_root = push_back_rec root shift v.size value in
    { root = Some new_root; size = v.size + 1; shift }

let rec iter_rec f node =
  match node with
  | Leaf leaf ->
    for j = 0 to leaf.count - 1 do
      f leaf.values.(j)
    done
  | Internal internal ->
    for j = 0 to branch - 1 do
      match internal.slots.(j) with
      | Some child -> iter_rec f child
      | None -> ()
    done

let iter f v =
  match v.root with
  | None -> ()
  | Some root -> iter_rec f root

(* Deterministic PRNG matching Zig *)
let random_f64 seed =
  let x = ref (Int64.of_int seed) in
  x := Int64.mul !x 6364136223846793005L;
  x := Int64.add !x 1442695040888963407L;
  x := Int64.logxor !x (Int64.shift_right !x 33);
  x := Int64.mul !x 0xFF51AFD7ED558CCDL;
  x := Int64.logxor !x (Int64.shift_right !x 33);
  x := Int64.mul !x 0xC4CEB9FE1A85EC53L;
  x := Int64.logxor !x (Int64.shift_right !x 33);
  let masked = Int64.logand !x 0xFFFFFFFFFFFFFL in
  (Int64.to_float masked) /. (Int64.to_float 0xFFFFFFFFFFFFFL)

let fused_frame v =
  let sum_x = ref 0.0 in
  let sum_y = ref 0.0 in
  let count = ref 0.0 in
  iter (fun p ->
    if p.alive then begin
      let dx = p.vel.x *. 0.016 in
      let dy = p.vel.y *. 0.016 in
      sum_x := !sum_x +. p.pos.x +. dx;
      sum_y := !sum_y +. p.pos.y +. dy;
      count := !count +. 1.0
    end
  ) v;
  if !count > 0.0 then
    { x = !sum_x /. !count; y = !sum_y /. !count }
  else
    { x = 0.0; y = 0.0 }

let () =
  let n = 1_000_000 in
  let frames = 60 in

  Printf.printf "=== OCaml Particle Simulation (%d particles, %d frames) ===\n" n frames;
  Printf.printf "OCaml 5.5.0\n\n";

  Gc.full_major ();
  Gc.full_major ();

  (* Build initial vector *)
  let v = ref (empty ()) in
  let t0 = Unix.gettimeofday () in
  for i = 0 to n - 1 do
    let p = {
      pos = { x = random_f64 (i * 3); y = random_f64 (i * 7 + 1) };
      vel = { x = random_f64 (i * 11 + 2); y = random_f64 (i * 13 + 3) };
      alive = i mod 10 <> 0;
    } in
    v := push_back !v p
  done;
  let build_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
  Printf.printf "  Build time: %.0fms\n" build_ms;

  (* Frame loop *)
  let times = Array.make frames 0.0 in
  let gc_times = Array.make frames 0.0 in
  for f = 0 to frames - 1 do
    let t0 = Unix.gettimeofday () in
    let center = fused_frame !v in
    let frame_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
    times.(f) <- frame_ms;
    ignore center;

    let gc0 = Unix.gettimeofday () in
    Gc.minor ();
    gc_times.(f) <- (Unix.gettimeofday () -. gc0) *. 1000.0
  done;

  (* Stats *)
  let total = ref 0.0 in
  let max_t = ref 0.0 in
  let min_t = ref max_float in
  let max_gc = ref 0.0 in
  let dropped = ref 0 in
  for f = 0 to frames - 1 do
    total := !total +. times.(f);
    max_t := max !max_t times.(f);
    min_t := min !min_t times.(f);
    max_gc := max !max_gc gc_times.(f);
    if times.(f) > 16.0 then incr dropped
  done;

  Printf.printf "\n── Per-Frame Latency ──\n";
  Printf.printf "  min:      %.1f ms\n" !min_t;
  Printf.printf "  avg:      %.1f ms\n" (!total /. float_of_int frames);
  Printf.printf "  max:      %.1f ms\n" !max_t;
  Printf.printf "  max GC:   %.3f ms\n" !max_gc;
  Printf.printf "  dropped:  %d/%d (>16ms)\n" !dropped frames;

  let mem = (Gc.stat ()).live_words in
  Printf.printf "  memory:   ~%.1f MB (live words)\n" (float_of_int mem *. 8.0 /. (1024.0 *. 1024.0))
