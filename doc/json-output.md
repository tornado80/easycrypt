# `easycrypt cli -json`: machine-readable goals

Format version: **`domino-json/2`**. Changes from version 1 are at the end.

`easycrypt cli -json` is the interactive top level (`easycrypt cli`) with structured output. The
input protocol is the one of `cli -emacs`: EasyCrypt reads EasyCrypt sentences from standard
input, and `undo N.` and `exit.` work as usual.

For **every** sentence that is processed, EasyCrypt writes **exactly one line** of JSON to standard
output, and nothing else. A client therefore sends a sentence, reads one line, and has the state
of the session after that sentence. There is no prompt.

Run it from a directory that does not contain an `easycrypt.project` you do not want to load.
Add `-I <dir>` as with any other mode.

```
easycrypt cli -json -I <dir> < script.ec
```

## Framing rules

- One answer per sentence: successes, errors, `undo`, `pragma`, `print`/`search`/`locate`, and
  `exit.` alike. A line is a complete JSON document with no embedded newline (newlines inside
  strings are escaped).
- Standard output carries nothing else. To make that hold for every part of EasyCrypt, the
  process moves its JSON stream to a private descriptor and re-points file descriptor 1 at
  standard error; whatever is printed through `Format.std_formatter` while a command runs (the
  output of `print`, `search`, `locate`) is captured and returned as a message of level `info`.
- Notices and warnings (`added lemma: ...`, `these procedures may use uninitialized local
  variables`, the copyright banner) are returned in `messages` of the answer to the sentence that
  produced them. **The banner, and any startup warning, therefore come in the `messages` of the
  first answer.**
- End of input is an implicit `exit.` and is answered with one more line (state unchanged).
- `SIGINT` interrupts the running command; it is answered with `"status": "interrupted"` and the
  session goes on. A `SIGINT` that arrives while EasyCrypt is only waiting for the next sentence
  interrupts nothing and is **not** answered.
- Standard error carries what EasyCrypt otherwise writes there (progress, prover chatter); it is
  free-form.

### Interrupts

1. A `SIGINT` that arrives while a sentence runs ends it with `"status": "interrupted"`, wherever
   it lands, including inside prover start-up and Why3 transformations of `smt`.
2. A `SIGINT` that arrives after the sentence finished (while its answer is being written) or
   between sentences is never answered and changes nothing.
3. There is never more than one line per sentence.

## The answer

```json
{"version": "domino-json/2",
 "state": 7,
 "status": "ok",
 "error": {"loc": {"start": 12, "end": 20}, "msg": "..."},
 "messages": [{"level": "warning", "text": "..."}],
 "proof": {"front": GOAL, "kinds": ["formula", "program", ...]},
 "timing": TIMING}
```

| field      | meaning |
|------------|---------|
| `version`  | always `"domino-json/2"` for this document |
| `state`    | the undo depth after the sentence: the number `N` for which `undo N.` returns to this state. A failure and a `pragma` do not push a level; a success does (`print`, `search` and `locate` too) |
| `status`   | `"ok"`, `"error"` or `"interrupted"` |
| `error`    | present only if `status` is not `"ok"`. `msg` is EasyCrypt's message. `loc` is `{"start", "end"}`, character offsets **inside the sentence** (the same as `[error-B-E]` of `-emacs`), or `null` if the error has no location |
| `messages` | notices produced while processing the sentence, in order. `level` is `debug`, `info`, `warning` or `critical` |
| `proof`    | `null` when there is no active proof; otherwise `{"front": GOAL or null, "kinds": [...]}`. `front` is the first open goal, in full. `kinds` has one entry for **each** open goal, in order, the front goal included: `"program"` for a judgement over two programs (`equiv[ S1 ~ S2 : ... ]`, kind `equivS` below), `"formula"` for every other goal. The number of open goals is the length of `kinds`. When the proof is complete and `qed.` is due, `front` is `null` and `kinds` is empty |

The `proof` field is present whatever the status: after a failing tactic it shows the goals as
they still are.

Only the front goal is printed. The other goals are not printed, whatever their number.

`undo N.` is answered with the answer of the state it returns to (whose `messages` are empty),
and its `proof` is exactly what the answer of state `N` had.

## Timing

The optional field `timing` tells where the time of the sentence went. It adds information only;
a reader that does not know it can ignore it (see "Compatibility"). All times are whole
milliseconds, rounded down, from a monotonic clock.

```json
{"tactic_ms": 812, "serialize_ms": 3,
 "smt": {"calls": 2, "translate_ms": 140, "prepare_ms": 95, "prover_ms": 6120,
         "valid": 1, "timeout": 1, "unknown": 0}}
```

| field          | meaning |
|----------------|---------|
| `tactic_ms`    | from the end of the parse of the sentence to the start of the serialization: the run of the sentence, `smt` included |
| `serialize_ms` | the time to build the `proof` field. The write of the line to standard output comes after this and is **not** included |
| `smt`          | present only if the sentence called a prover |
| `calls`        | the number of calls to the provers. One `smt` can make more than one call (lemma selection) |
| `translate_ms` | the time in the SMT check that is not in a call: the translation of the goal to Why3, and the build of the task of each call |
| `prepare_ms`   | the time in Why3's `Driver.prove_task` (transformations such as `eliminate_epsilon`, and the start of the prover process), summed over all provers of all calls. The prover time limit does not apply to it |
| `prover_ms`    | the wall time of the calls, from the start of the first prover to the end of the wait for the last one, minus `prepare_ms`, summed over calls. Provers run in parallel, so this is wall time, not CPU time |
| `valid`, `timeout`, `unknown` | the results of the calls. `timeout`: no prover proved the goal and at least one hit the time limit. `unknown`: every other failure (a prover gave up, disproved the goal, failed, or the call was interrupted). The three sum to `calls` |

The sums are reset at the start of each sentence. `tactic_ms + serialize_ms` is never more than
the wall time that the client measures from send to answer.

## Goals

```json
{"id": 1, "tvars": ["'a"], "hyps": [ HYP, ... ], "concl": FORM, "text": "..."}
```

- `id`: the position of the goal among the open goals, from 1. For `front` it is always 1.
- `tvars`: the type variables in scope, as displayed.
- `hyps`: the context in the order EasyCrypt displays it (oldest first).
- `concl`: the conclusion, a `FORM` (below).
- `text`: the goal exactly as `cli` would print it (with hypotheses, at the configured `PP:width`).
  For humans and for debugging.

A hypothesis:

```json
{"name": "x", "ident": IDENT, "kind": "var" | "mem" | "modty" | "hyp" | "abs_st", ...}
```

`name` is the name EasyCrypt displays, so it is valid in a tactic. It is not the identifier's
own name when EasyCrypt renamed it to avoid a clash (`y0`). The other fields depend on `kind`:

| kind     | fields |
|----------|--------|
| `var`    | `type`: TYPE; `body`: FORM, only for a `let`-bound variable |
| `mem`    | `memtype`: MEMTYPE |
| `modty`  | `modtype`: `{"params": "...", "pp": "..."}` (text only) |
| `hyp`    | `form`: FORM |
| `abs_st` | `pp` (text only) |

`IDENT` is `{"name": "x", "tag": 13763}`. The pair identifies a binder: two binders called `x`
have different tags. Tags are unique within a session (a process), not across sessions.

## Nodes

Every node of a tree is an object with `kind`. Some nodes also have `pp`: the node's own
EasyCrypt text, on one line (statements keep their own line breaks), printed in the context the
node lives in: the names of the binders above it, and the memory that is active there. In a
precondition, program variables carry their side (`b{1}`); inside a program they do not.

`pp` is on these nodes only:

- the root FORM of `concl`, of a `hyp`'s `form`, and of a `var` hypothesis's `body`;
- every TYPE node;
- every INSTR, every LVALUE and the PVARs in it;
- the EXPR root of the `cond` of an `if` or `while` instruction.

The other FORM and EXPR nodes have no `pp`. A client that needs the text of such a node prints
it itself.

Paths (`EcPath`) are the printed qualified name (`"Top.Pervasive.="`); a procedure is
`{"path": "Top.M./f", "top": "Top.M", "name": "f", "pp": "M.f"}`.

### TYPE

`{"kind": K, "pp": "...", ...}` with `K` one of:

| kind     | fields |
|----------|--------|
| `constr` | `path`, `args`: [TYPE] |
| `tuple`  | `items`: [TYPE] |
| `fun`    | `arg`, `res`: TYPE |
| `var`    | `ident` |
| `glob`   | `module`: IDENT |
| `univar` | none |

### MEMTYPE

`{"pp": "...", "arg": "arg" | null, "locals": [{"name": "b", "type": TYPE}, ...]}`. `arg` is
the name of the tuple of the arguments when there is one.

### FORM

Every FORM has `ty`: TYPE. Kinds:

| kind        | fields |
|-------------|--------|
| `int`       | `value`: decimal string |
| `local`     | `name`, `ident` |
| `pvar`      | `scope` (`"local"` or `"global"`), `name` (local) or `path` (global), `mem`, `mem_ident` |
| `glob`      | `module`, `ident`, `mem`, `mem_ident` |
| `op`        | `path`, `name`, `tyargs`: [TYPE] |
| `app`       | `op`: the operator path if the head is an operator, else `null`; `head`: FORM; `args`: [FORM] |
| `tuple`     | `items` |
| `proj`      | `arg`, `index` |
| `if`        | `cond`, `then`, `else` |
| `match`     | `scrutinee`, `branches`: [FORM] |
| `let`       | `pattern`: `{"kind": "symbol" or "tuple" or "record", "binders": [BINDER]}`, `bound`, `body` |
| `quant`     | `quantifier`: `"forall"`, `"exists"` or `"lambda"`; `binders`; `body` |
| `hoareS` `phoareS` `ehoareS` | `program`: SIDE; `pre`; `post`, `exn` (hoare); `post` (ehoare, phoare); phoare also `cmp` (`[<=]`, `[=]`, `[>=]`) and `bd`: FORM |
| `hoareF` `phoareF` `ehoareF` | `proc`, `mem`, `pre`, `post`, `exn` (hoare), `cmp` and `bd` (phoare) |
| `equivS`    | `left`, `right`: SIDE; `pre`, `post` |
| `equivF`    | `left`, `right`: `{"mem", "ident", "proc"}`; `pre`, `post` |
| `eagerF`    | `left`, `right`: `{"mem", "ident", "proc", "stmt", "stmt_pp"}`; `pre`, `post` |
| `pr`        | `proc`, `mem`, `args`: FORM, `event_mem`, `event`: FORM |

Operators such as `inv` (a user's predicate) appear as `app` with `op` set to the operator's path
(`Top.<File>.inv`).

A quantifier's `BINDER` is `{"name", "ident", "kind": "var" | "mem" | "modty", ...}`: `var` (a
value, with `type`), `mem` (a memory, with `memtype`) or `modty` (a module, with `modtype`). A `let` or `match` binder is
`{"name", "ident", "type"}`. Binder names are the ones displayed, and are what the names in the
body refer to.

`exn` (hoare) is a list of `{"exn": path | null, "form": FORM}`, empty unless the judgement has
exceptional postconditions.

### SIDE

`{"mem": "&1", "ident", "memtype": MEMTYPE, "stmt": [INSTR], "stmt_pp": "..."}`. `mem` is the
memory as displayed, `stmt` the program, `stmt_pp` its text.

### INSTR

A program is a list of instruction nodes. Every instruction has `kind` and `pp`. Of the EXPRs
in an instruction, only a `cond` has `pp`.

| kind       | fields |
|------------|--------|
| `asgn`     | `lvalue`: LVALUE, `expr`: EXPR |
| `rnd`      | `lvalue`, `expr` (the distribution) |
| `call`     | `lvalue`: LVALUE or `null`, `proc`, `args`: [EXPR] |
| `if`       | `cond`: EXPR, `then`: [INSTR], `else`: [INSTR] |
| `while`    | `cond`, `body`: [INSTR] |
| `match`    | `scrutinee`, `branches`: [`{"binders", "body"}`] |
| `raise`    | `expr` |
| `abstract` | `name`: IDENT |

`LVALUE` is `{"kind": "var" | "tuple", "pp", "vars": [PVAR]}` where a `PVAR` is
`{"kind": "pvar", "pp", "scope", "name" or "path", "ty": TYPE}`.

### EXPR

The same as FORM without the program-logic kinds and the memory fields: `int`, `local`, `pvar`
(`scope`, `name` or `path`), `op`, `app`, `quant`, `let`, `tuple`, `if`, `match`, `proj`, each
with `ty`.

## Example

`proc; inline *.` on an equivalence of two copies of a procedure with a nested `if` and a
sampling gives, abridged:

```json
{"version":"domino-json/2","state":6,"status":"ok","messages":[],
 "proof":{"kinds":["program"],
  "front":{"id":1,"tvars":[],"hyps":[{"name":"&m","kind":"mem",...}],
  "concl":{"kind":"equivS","pp":"equiv[...]",
   "left":{"mem":"&1","ident":{"name":"&1","tag":1234},
           "memtype":{"pp":"{a : int, b : bool}","arg":null,
                      "locals":[{"name":"a","type":{"kind":"constr","pp":"int",...}},...]},
           "stmt":[{"kind":"if","pp":"if (a = 0) {...}",
                    "cond":{"kind":"app","pp":"a = 0",...},
                    "then":[{"kind":"rnd","pp":"b <$ {0,1};",
                             "lvalue":{"kind":"var","pp":"b",...},
                             "expr":{"kind":"op",...}}],
                    "else":[{"kind":"if",...}]}],
           "stmt_pp":"if (a = 0) {\n  b <$ {0,1};\n} else {...}"},
   "right":{...},
   "pre":{"kind":"app","op":"Top.Pervasive.=",...},
   "post":{"kind":"app",...}},
  "text":"..."}}}
```

## Size

Nothing is truncated or elided. One goal is printed in full, whatever the number of open goals.
A goal is a few times the size of its text, and a goal with a record literal of a few hundred
lines runs to hundreds of kilobytes. Read a line at a time.

## Compatibility

The version string changes when a field is removed or changes meaning. Fields and node kinds may
be added without a version change: readers must ignore what they do not know.

## Changes from `domino-json/1`

- `proof` was `{"goals": [GOAL, ...]}`, every open goal in full. It is now
  `{"front": GOAL or null, "kinds": [...]}`: the first goal in full, and the kind of each goal.
- `pp` was on every node. It is now only on the nodes listed in "Nodes".
- A value binder of a quantifier had the kind `"type"`. It now has the kind `"var"`.

Why: with every goal and a `pp` on every node, an answer at a proof with 16 open goals was
25-28 MB, and writing it took most of the time of a sentence.
