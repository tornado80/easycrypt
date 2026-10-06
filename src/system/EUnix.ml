(* -------------------------------------------------------------------- *)
external setpgid : int -> int -> unit = "caml_eunix_setpgid"
external monotonic : unit -> float = "caml_eunix_monotonic"
