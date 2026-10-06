(* -------------------------------------------------------------------- *)
open EcUtils

module L  = Lexing
module LC = EcLocation

(* -------------------------------------------------------------------- *)
type status =[
  | `ST_Ok
  | `ST_Failure of exn
]

type loglevel = EcGState.loglevel

class type terminal =
object
  method interactive : bool
  method next        : string * EcParsetree.prog
  method notice      : immediate:bool -> loglevel -> string -> unit
  method finish      : status -> unit
  method finalize    : unit
  method setwidth    : int -> unit
end

(* -------------------------------------------------------------------- *)
let interactive (t : terminal) =
  t#interactive

let next (t : terminal) =
  t#next

let notice ~immediate lvl msg (t : terminal) =
  t#notice ~immediate lvl msg

let finish status (t : terminal) =
  t#finish status

let finalize (t : terminal) =
  t#finalize

let setwidth (t : terminal) (i : int) =
  t#setwidth i

(* -------------------------------------------------------------------- *)
class from_emacs () : terminal =
object(self)
  val mutable startpos = 0
  val mutable notices  = []
  val (*---*) iparser  = EcIo.from_channel ~name:"<emacs>" stdin

  method interactive = true

  method private _notice (lvl, msg) =
    let prefix =
      match lvl with
      | `Debug | `Warning | `Critical -> "[W]"
      | `Info -> ""
    in
      List.iteri
        (fun i x ->
          Format.printf "%s%s%s\n%!"
          prefix (if i = 0 then "+ " else "| ") x)
        (String.split_lines msg)

  method next =
    begin
      let lexbuf = EcIo.lexbuf iparser in
        EcIo.drain iparser;
        startpos <- lexbuf.L.lex_curr_p.L.pos_cnum
    end;

    Format.printf "[%d|%s]>\n%!" (EcCommands.uuid ()) (EcCommands.mode ());
    EcIo.xparse iparser

  method notice ~(immediate:bool) (lvl : loglevel) (msg : string) =
    match immediate with
    | true  -> self#_notice (lvl, msg)
    | false -> notices <- (lvl, msg) :: notices

  method finish (status : status) =
    List.iter self#_notice (List.rev notices);

    match status with
    | `ST_Ok ->
        EcCommands.pp_maybe_current_goal Format.std_formatter

    | `ST_Failure e ->
        let (loc, e) =
          match e with
          | EcScope.TopError (loc, e) -> (loc, e)
          | _ -> (LC._dummy, e)
        in
          Format.fprintf Format.err_formatter
            "[error-%d-%d]%s\n%!"
            (max 0 (loc.LC.loc_bchar - startpos))
            (max 0 (loc.LC.loc_echar - startpos))
            (EcPException.tostring e)

  method finalize =
    EcIo.finalize iparser

  method setwidth (i : int) =
    Format.pp_set_margin Format.std_formatter i;
    Format.pp_set_margin Format.err_formatter i
end

let from_emacs () = new from_emacs ()

(* -------------------------------------------------------------------- *)
(* [cli -json]: exactly one line of JSON on stdout per sentence, and
 * nothing else. See doc/json-output.md for the format.
 *
 * To make "nothing else" hold whatever the rest of EasyCrypt does, the
 * constructor moves the JSON stream to a private duplicate of the original
 * stdout, and points file descriptor 1 at stderr; whatever is written to
 * [Format.std_formatter] (e.g., by `print`, `search`, `locate`) is captured
 * and reported in the [messages] field of the sentence's answer. *)
module Json = struct
  let version = "domino-json/2"

  (* [`Null] if there is no proof. Otherwise the first open goal in full
     ([`Null] if none is open) and the kind of every open goal, the first
     included: only the first goal is printed, whatever the number. *)
  let proof () : Yojson.Safe.t =
    let scope = EcCommands.current () in

    match EcScope.xgoal scope with
    | Some { EcScope.puc_active = Some ({ EcScope.puc_jdg = EcScope.PSCheck pf }, _) } ->
        let ppe   = EcPrinting.PPEnv.ofenv (EcScope.env scope) in
        let goals = EcCoreGoal.all_opened pf in
        let front { EcCoreGoal.g_hyps; EcCoreGoal.g_concl } =
          match EcPrinting.goal_to_json ppe (EcEnv.LDecl.tohyps g_hyps, g_concl) with
          | `Assoc fields -> `Assoc (("id", `Int 1) :: fields)
          | j -> j in
        let kind { EcCoreGoal.g_concl } =
          match g_concl.EcAst.f_node with
          | EcAst.FequivS _ -> `String "program"
          | _ -> `String "formula" in
        `Assoc [("front", match goals with [] -> `Null | g :: _ -> front g);
                ("kinds", `List (List.map kind goals))]

    | _ -> `Null

  let ms (s : float) = `Int (EcTiming.ms s)

  (* Times in seconds. *)
  let timing ~(tactic : float) ~(serialize : float) : Yojson.Safe.t =
    let smt (t : EcTiming.smt) =
      `Assoc [("calls"       , `Int t.calls);
              ("translate_ms", `Int t.translate_ms);
              ("prepare_ms"  , `Int t.prepare_ms);
              ("prover_ms"   , `Int t.prover_ms);
              ("valid"       , `Int t.valid);
              ("timeout"     , `Int t.timeout);
              ("unknown"     , `Int t.unknown)] in
    `Assoc ([("tactic_ms", ms tactic); ("serialize_ms", ms serialize)]
            @ (EcTiming.smt () |> Option.map (fun t -> ("smt", smt t))
                               |> Option.to_list))

  let strip = function EcScope.TopError (_, e) -> e | e -> e

  let is_interrupt = function
    | EcScope.HiScopeError (None, "interrupted") -> true
    | _ -> false
end

class from_json () : terminal =
object(self)
  val mutable startpos = 0
  val mutable notices  = []
  (* No sentence is in flight: from the end of an answer (or the start)
     until the next sentence is parsed. *)
  val mutable idle     = true
  (* When the sentence in flight was parsed. *)
  val mutable started  = EcTiming.now ()
  val (*---*) iparser  = EcIo.from_channel ~name:"<json>" stdin
  val (*---*) captured = Buffer.create 256
  val (*---*) out      =
    flush stdout;
    let out = Unix.out_channel_of_descr (Unix.dup Unix.stdout) in
    Unix.dup2 Unix.stderr Unix.stdout; out

  initializer
    Format.pp_set_formatter_output_functions Format.std_formatter
      (fun s p n -> Buffer.add_substring captured s p n)
      (fun () -> ())

  method interactive = true

  method next =
    idle <- true;
    begin
      let lexbuf = EcIo.lexbuf iparser in
        EcIo.drain iparser;
        startpos <- lexbuf.L.lex_curr_p.L.pos_cnum
    end;
    let sentence = EcIo.xparse iparser in
    EcTiming.reset ();
    started <- EcTiming.now ();
    idle <- false; sentence

  method notice ~(immediate : bool) (lvl : loglevel) (msg : string) =
    ignore immediate;
    notices <- (lvl, msg) :: notices

  method private messages =
    Format.pp_print_flush Format.std_formatter ();
    let printed = String.strip (Buffer.contents captured) in
    Buffer.clear captured;
    let pending = List.rev notices in
    notices <- [];
    let msg (lvl, text) =
      `Assoc [("level", `String (EcGState.string_of_loglevel lvl));
              ("text" , `String text)] in
    List.map msg (pending @ (if printed = "" then [] else [(`Info, printed)]))

  method finish (status : status) =
    (* An interrupt that arrives while no sentence is in flight (after an
       answer, or while we wait for the next sentence) does not interrupt
       any command: it is not answered, so that there is exactly one
       answer per sentence. *)
    match status with
    | `ST_Failure e when idle && Json.is_interrupt (Json.strip e) -> ()
    | _ ->
        (* The sentence has finished: an interrupt while we answer it
           changes nothing, so it is held back and dropped. *)
        let old = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> ())) in
        EcUtils.try_finally
          (fun () -> self#answer status)
          (fun () -> idle <- true; Sys.set_signal Sys.sigint old)

  method private answer (status : status) =
    let status, error =
      match status with
      | `ST_Ok -> ("ok", [])

      | `ST_Failure e ->
          let (loc, e) =
            match e with
            | EcScope.TopError (loc, e) -> (loc, e)
            | _ -> (LC._dummy, e) in
          let jloc =
            if LC.isdummy loc then `Null else
              `Assoc [("start", `Int (max 0 (loc.LC.loc_bchar - startpos)));
                      ("end"  , `Int (max 0 (loc.LC.loc_echar - startpos)))] in
          let msg = String.strip (EcPException.tostring e) in
          ((if Json.is_interrupt e then "interrupted" else "error"),
           [("error", `Assoc [("loc", jloc); ("msg", `String msg)])])
    in

    let serializing = EcTiming.now () in
    let proof =
      try Json.proof ()
      with e ->
        notices <- (`Critical,
                    "cannot serialize the goals: " ^ Printexc.to_string e)
                   :: notices;
        `Null in
    let timing =
      Json.timing
        ~tactic:(serializing -. started)
        ~serialize:(EcTiming.now () -. serializing) in

    let answer =
      `Assoc ([("version", `String Json.version);
               ("state"  , `Int (EcCommands.uuid ()));
               ("status" , `String status)]
              @ error
              @ [("messages", `List self#messages);
                 ("proof"   , proof);
                 ("timing"  , timing)]) in

    output_string out (Yojson.Safe.to_string answer);
    output_char out '\n';
    flush out

  method finalize =
    EcIo.finalize iparser

  method setwidth (i : int) =
    Format.pp_set_margin Format.std_formatter i;
    Format.pp_set_margin Format.err_formatter i
end

let from_json () = new from_json ()

(* -------------------------------------------------------------------- *)
class from_tty () : terminal =
object
  val iparser = EcIo.from_channel ~name:"<tty>" stdin

  method interactive = true

  method next =
    Format.printf "[%d|%s]>\n%!" (EcCommands.uuid ()) (EcCommands.mode ());
    EcIo.drain iparser;
    EcIo.xparse iparser

  method notice ~(immediate:bool) (_ : loglevel) (msg : string) =
    ignore immediate;
    List.iter
      (fun x -> Format.eprintf "%s\n%!" x)
      (String.split_lines msg)

  method finish (status : status) =
    match status with
    | `ST_Ok ->
        EcCommands.pp_maybe_current_goal Format.std_formatter

    | `ST_Failure e ->
        EcPException.exn_printer Format.err_formatter e

  method finalize =
    EcIo.finalize iparser

  method setwidth (i : int) =
    Format.pp_set_margin Format.std_formatter i;
    Format.pp_set_margin Format.err_formatter i
end

let from_tty () = new from_tty ()

(* -------------------------------------------------------------------- *)
type progress = [ `Human | `Script | `Silent ]

class from_channel
  ?(gcstats  : bool = true)
  ?(progress : progress option)
  ?(lastgoals : bool = false)
  ~(name      : string)
   (stream    : in_channel)
  : terminal

= object(self)
  val ticks = "-\\|/"

  val (*---*) iparser = EcIo.from_channel ~name stream
  val mutable sz       = -1
  val mutable tick     = -1
  val mutable loc      = LC._dummy
  val mutable gc       = None
  val mutable progress =
    progress |> ofdfl (fun () ->
      if
        (Sys.os_type = "Unix") &&
        (Unix.isatty (Unix.descr_of_out_channel stderr))
      then `Human else `Silent)

  method private _do_update_progress =
    match progress with
    | (`Human | `Script) as progress -> begin
        let lineno   = fst (loc.LC.loc_end) in
        let position = loc.LC.loc_echar in
        let ratio    =
          match sz with
          | _ when sz < 0 -> None
          | _ when sz = 0 -> Some 1.0
          | _ -> Some ((float_of_int position) /. (float_of_int sz)) in

        let mem, unu =
          if not gcstats then -1., -1. else
          match gc with
          | Some (mem, unu, btick) when btick > tick-20 ->
             (mem, unu)
          | _ ->
             let stats = Gc.stat () in
             let mem = stats.Gc.live_words in
             let mem = (float_of_int mem) *. (float_of_int (Sys.word_size / 8)) in
             let unu = stats.Gc.fragments in
             let unu = (float_of_int unu) *. (float_of_int (Sys.word_size / 8)) in
             gc <- Some (mem, unu, tick); (mem, unu)
        in

        tick <- tick + 1;

        match progress with
        | `Human -> begin
            let rec human x st all =
              match all with
              | [] -> (x, st)
              | _ when x < 1024.-> (x, st)
              | st' :: all -> human (x /. 1024.) st' all in

            let mem, memst = human mem "B" ["kB"; "MB"; "GB"] in
            let unu, unust = human unu "B" ["kB"; "MB"; "GB"] in
            let ratio = ratio
               |> omap (( *. ) 100.)
               |> omap (Format.sprintf "%.1f")
               |> odfl "?.?" in

            Format.eprintf "[%c] [%.4d] %s%% (%.1f%s / [frag %.1f%s])\r%!"
              ticks.[tick mod (String.length ticks)] lineno
              ratio mem memst unu unust
          end

        | `Script -> begin
            let lineno   = fst (loc.LC.loc_end) in
            let position = loc.LC.loc_echar in
            let ratio    =
              ratio
              |> omap (fun x -> Format.sprintf "%.5f" x)
              |> odfl "-" in

            Format.eprintf
              "P %d %d %s %.2f %.2f@."
              lineno position ratio mem unu
          end
      end

    | _ -> ()

  method private _update_progress =
    if loc !=(*phy*) LC._dummy then
      self#_do_update_progress

  method private _clean_progress_line ?(erase = true) () =
    match progress with
    | `Human when erase ->
       if sz >= 0 then
         let fmt = "[*] [----] ---.- (------.-?B% - [---- ------.-?B%])" in
         Format.eprintf "%*s\r%!" (String.length fmt) ""

    | `Human ->
       Format.eprintf "\n%!"

    | `Script | `Silent ->
       ()

  method private _notice ?subloc ~immediate (lvl : loglevel) (msg : string) =
    let (_ : unit) = ignore immediate in

    if EcGState.accept_log ~level:`Warning ~wanted:lvl then
      let prefix = EcGState.string_of_loglevel lvl in
      let strloc =
        match subloc with
        | None -> Format.sprintf "%s:%d" name (fst (loc.LC.loc_end))
        | Some loc -> LC.tostring loc
      in
        self#_clean_progress_line ();
        begin match progress with
        | `Human ->
           Format.eprintf "[%s] [%s] %s\n%!" prefix strloc msg
        | `Script ->
           Format.eprintf "E %s %s %s\n%!" prefix strloc (String.escaped msg)
        | `Silent ->
           Format.eprintf "[%s] [%s] %s\n%!" prefix strloc msg
        end;
        self#_update_progress

  method interactive = false

  method next =
    let aout = EcIo.xparse iparser in
    loc <- (snd aout).LC.pl_loc;
    self#_update_progress; aout

  method notice ~immediate lvl msg =
    self#_notice ~immediate lvl msg

  method finish (status : status) =
    match status with
    | `ST_Ok -> ()

    | `ST_Failure e -> begin
        let (subloc, e) =
          match e with
          | EcScope.TopError (loc, e) -> (Some loc, e)
          | _ -> (None, e) in
        let msg = String.strip (EcPException.tostring e) in

        self#_clean_progress_line ();
        if lastgoals then
          EcCommands.pp_current_goal_or_noproof ~all:true Format.std_formatter;
        self#_notice ?subloc ~immediate:true `Critical msg;
        self#_update_progress;
        self#_clean_progress_line ~erase:false ();
        progress <- `Silent
      end

  method finalize =
    self#_clean_progress_line ();
    progress <- `Silent;
    EcIo.finalize iparser

  initializer begin
    try
      let fd   = Unix.descr_of_in_channel stream in
      let stat = Unix.fstat fd in
      sz <- stat.Unix.st_size
    with Unix.Unix_error _ -> ()
  end

  method setwidth (i : int) =
    Format.pp_set_margin Format.std_formatter i;
    Format.pp_set_margin Format.err_formatter i
end

let from_channel ?gcstats ?progress ?lastgoals ~name stream =
  new from_channel ?gcstats ?progress ?lastgoals ~name stream
