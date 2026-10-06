
(* -------------------------------------------------------------------- *)
val setpgid : int -> int -> unit
(* Seconds on a clock that never goes back (CLOCK_MONOTONIC); only the
   difference of two readings has a meaning. *)
val monotonic : unit -> float
