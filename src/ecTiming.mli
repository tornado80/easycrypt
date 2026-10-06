(* -------------------------------------------------------------------- *)
(* Where the time of one sentence goes, for the [timing] field of
 * [cli -json] (doc/json-output.md).
 *
 * The sums are global and cover one sentence: [reset] starts a new
 * sentence. The SMT code reports to this module through the wrappers
 * below, so that no argument goes through the tactic engine. All times
 * come from a monotonic clock.
 *
 * Invariants, for any sentence:
 * - [valid + timeout + unknown = calls];
 * - [translate], [prepare] and [prover] are disjoint parts of the time
 *   in [check] and [call]; time in a [call] is never in [translate].
 * Each wrapper adds its time and re-raises any exception of its
 * argument; a [call] that raises counts as [unknown]. *)

type outcome = [ `Valid | `Timeout | `Unknown ]

type smt = {
  calls        : int;
  translate_ms : int;
  prepare_ms   : int;
  prover_ms    : int;
  valid        : int;
  timeout      : int;
  unknown      : int;
}

(* Seconds on a monotonic clock. *)
val now : unit -> float

(* Whole milliseconds in [s] seconds, rounded down: a sum of [ms] is
   never more than [ms] of the sum. *)
val ms : float -> int

(* Forgets the sums of the previous sentence. *)
val reset : unit -> unit

(* [check f] runs one SMT check ([EcSmt.check]). Its time, minus the time
   of the [call]s it makes, is translation. *)
val check : (unit -> 'a) -> 'a

(* [call ~outcome f] runs one call to the provers
   ([EcProvers.execute_task]); [outcome] classifies its result. Its time,
   minus the time of [prepare], is prover time. *)
val call : outcome:('a -> outcome) -> (unit -> 'a) -> 'a

(* [prepare f] runs Why3's preparation of a task for one prover
   ([Driver.prove_task]: transformations and start of the process). *)
val prepare : (unit -> 'a) -> 'a

(* The sums of this sentence; [None] if it called no prover. *)
val smt : unit -> smt option
