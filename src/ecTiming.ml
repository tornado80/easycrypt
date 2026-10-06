(* -------------------------------------------------------------------- *)
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

type sums = {
  mutable calls     : int;
  mutable check     : float;   (* in [check], [call]s included *)
  mutable in_checks : float;   (* in a [call] made by a [check] *)
  mutable call      : float;   (* in [call], [prepare] included *)
  mutable prepare   : float;
  mutable valid     : int;
  mutable timeout   : int;
  mutable unknown   : int;
}

let sums = {
  calls = 0; check = 0.; in_checks = 0.; call = 0.; prepare = 0.;
  valid = 0; timeout = 0; unknown = 0;
}

let now = EUnix.monotonic

let reset () =
  sums.calls <- 0; sums.check <- 0.; sums.in_checks <- 0.;
  sums.call <- 0.; sums.prepare <- 0.;
  sums.valid <- 0; sums.timeout <- 0; sums.unknown <- 0

let timed (add : float -> unit) (f : unit -> 'a) : 'a =
  let t0 = now () in
  EcUtils.try_finally f (fun () -> add (now () -. t0))

let check f =
  let calls0 = sums.call in
  timed (fun dt ->
      sums.check     <- sums.check +. dt;
      sums.in_checks <- sums.in_checks +. (sums.call -. calls0))
    f

let count = function
  | `Valid   -> sums.valid   <- sums.valid   + 1
  | `Timeout -> sums.timeout <- sums.timeout + 1
  | `Unknown -> sums.unknown <- sums.unknown + 1

let call ~outcome f =
  sums.calls <- sums.calls + 1;
  let r =
    try timed (fun dt -> sums.call <- sums.call +. dt) f
    with e -> count `Unknown; raise e in
  count (outcome r); r

let prepare f =
  timed (fun dt -> sums.prepare <- sums.prepare +. dt) f

let ms (s : float) = int_of_float (floor (s *. 1000.))

let smt () =
  if sums.calls = 0 then None else Some {
    calls        = sums.calls;
    translate_ms = ms (sums.check -. sums.in_checks);
    prepare_ms   = ms sums.prepare;
    prover_ms    = ms (sums.call -. sums.prepare);
    valid        = sums.valid;
    timeout      = sums.timeout;
    unknown      = sums.unknown;
  }
