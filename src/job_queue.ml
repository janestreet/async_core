open! Core_kernel.Std
open! Import

module Scheduler = Types.Scheduler

let dummy_e = Execution_context.main
let dummy_f : Obj.t -> unit = ignore
let dummy_a : Obj.t = Obj.repr ()

module A = Core_kernel.Obj_array

let slots_per_elt = 3

(* This is essentially a specialized [Flat_queue], done for reasons of speed. *)
type t = Types.Job_queue.t =
  { mutable num_jobs_run         : int
  ; mutable jobs_left_this_cycle : int
  (* [jobs] is an array of length [capacity t * slots_per_elt], where each elt has the
     three components of a job ([execution_context], [f], [a]) in consecutive spots in
     [jobs].  [enqueue] doubles the length of [jobs] if [jobs] is full.  [jobs] never
     shrinks. *)
  ; mutable jobs                 : A.t
  (* [mask] is [capacity t - 1], and is used for quickly computing [i mod (capacity
     t)] *)
  ; mutable mask                 : int
  (* [front] is the index of the first job in the queue.  The array index of that job's
     execution context is [front * slots_per_elt]. *)
  ; mutable front                : int
  ; mutable length               : int
  }
with fields, sexp_of

let offset t i = ((t.front + i) land t.mask) * slots_per_elt

let capacity t = t.mask + 1

let invariant t : unit =
  Invariant.invariant _here_ t <:sexp_of< t >> (fun () ->
    let check f = Invariant.check_field t f in
    Fields.iter
      ~num_jobs_run:(check (fun num_jobs_run ->
        assert (num_jobs_run >= 0)))
      ~jobs_left_this_cycle:(check (fun jobs_left_this_cycle ->
        assert (jobs_left_this_cycle >= 0)))
      ~jobs:(check (fun jobs ->
        for i = 0 to t.length - 1 do
          Execution_context.invariant (Obj.obj (A.get jobs (offset t i))
                                       : Execution_context.t);
        done))
      ~mask:(check (fun mask ->
        let capacity = mask + 1 in
        assert (Int.is_pow2 capacity);
        assert (capacity * slots_per_elt = A.length t.jobs)))
      ~front:(check (fun front ->
        assert (front >= 0);
        assert (front < capacity t)))
      ~length:(check (fun length ->
        assert (length >= 0);
        assert (length <= capacity t))))
;;

let create_array ~capacity = A.create ~len:(capacity * slots_per_elt)

let create () =
  let capacity = 1 in
  { num_jobs_run         = 0
  ; jobs_left_this_cycle = 0
  ; jobs                 = create_array ~capacity
  ; mask                 = capacity - 1
  ; front                = 0
  ; length               = 0
  }
;;

let clear t = t.front <- 0; t.length <- 0; t.jobs_left_this_cycle <- 0

let grow t =
  let old_capacity = capacity t in
  let new_capacity = old_capacity * 2 in
  let old_jobs = t.jobs in
  let old_front = t.front in
  let len1 = (Int.min t.length (old_capacity - old_front)) * slots_per_elt in
  let len2 = t.length * slots_per_elt - len1 in
  let new_jobs = create_array ~capacity:new_capacity in
  A.blit ~len:len1
    ~src:old_jobs ~src_pos:(old_front * slots_per_elt)
    ~dst:new_jobs ~dst_pos:0;
  A.blit ~len:len2
    ~src:old_jobs ~src_pos:0
    ~dst:new_jobs ~dst_pos:len1;
  t.mask <- new_capacity - 1;
  t.jobs <- new_jobs;
  t.front <- 0;
;;

let set (type a) t i execution_context f a =
  let offset = offset t i in
  A.unsafe_set t.jobs  offset      (Obj.repr (execution_context : Execution_context.t));
  A.unsafe_set t.jobs (offset + 1) (Obj.repr (f : a -> unit));
  A.unsafe_set t.jobs (offset + 2) (Obj.repr (a : a));
;;

let enqueue t execution_context f a =
  if t.length = capacity t then grow t;
  set t t.length execution_context f a;
  t.length <- t.length + 1;
;;

let set_jobs_left_this_cycle t n =
  if n < 0
  then failwiths "Jobs.set_jobs_left_this_cycle got negative number" (n, t)
         <:sexp_of< int * t >>;
  t.jobs_left_this_cycle <- n;
;;

let can_run_a_job t = t.length > 0 && t.jobs_left_this_cycle > 0

let run_job t (scheduler : Scheduler.t) execution_context f a =
  if Execution_context.is_alive execution_context
       ~global_kill_index:scheduler.global_kill_index
  then begin
    t.num_jobs_run <- t.num_jobs_run + 1;
    Scheduler.set_execution_context scheduler execution_context;
    f a;
  end;
;;

let run_external_jobs t (scheduler : Scheduler.t) =
  let external_jobs = scheduler.external_jobs in
  while Thread_safe_queue.length external_jobs > 0 do
    let External_job.T (execution_context, f, a) =
      Thread_safe_queue.dequeue_exn external_jobs
    in
    run_job t scheduler execution_context f a;
  done;
;;

let run_jobs (type a) t scheduler =
  (* We do the [try-with] outside of the [while] because it is cheaper than doing a
     [try-with] for each job. *)
  try
    (* [run_external_jobs] before entering the loop, since it might enqueue a job,
       changing [t.length]. *)
    run_external_jobs t scheduler;
    while can_run_a_job t do
      let this_job = offset t 0 in
      let execution_context =
        (Obj.obj (A.unsafe_get t.jobs this_job) : Execution_context.t)
      in
      let f = (Obj.obj (A.unsafe_get t.jobs (this_job + 1)) : a -> unit) in
      let a = (Obj.obj (A.unsafe_get t.jobs (this_job + 2)) : a        ) in
      (* We clear out the job right now so that it isn't live at the next minor
         collection.  We tried not doing this and saw significant (15% or so) performance
         hits due to spurious promotion. *)
      set t 0 dummy_e dummy_f dummy_a;
      t.front <- (t.front + 1) land t.mask;
      t.length <- t.length - 1;
      t.jobs_left_this_cycle <- t.jobs_left_this_cycle - 1;
      (* It is OK if [run_job] or [run_external_jobs] raises, in which case the exn is
         handled by the outer try-with.  The only side effects we have done are to take
         the job out of the queue and decrement [jobs_left_this_cycle].  [run_job] or
         [run_external_jobs] may side effect [t], either by enqueueing jobs, or by
         clearing [t]. *)
      run_job t scheduler execution_context f a;
      (* [run_external_jobs] at each iteration of the [while] loop, for fairness. *)
      run_external_jobs t scheduler;
    done;
    Result.ok_unit
  with exn ->
    (* We call [Exn.backtrace] immediately after catching an unhandled exception, to
       ensure there is no intervening code that interferes with the global backtrace
       state. *)
    let backtrace = Exn.backtrace () in
    Error (exn, backtrace)
;;