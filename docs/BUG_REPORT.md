# hwfl Bug Report

- **Date:** 2026-08-05 (initial); **amended 2026-08-12** (MCP / concurrency
  follow-up and docs sync)
- **Scope:** `src/Hwfl/**`, `app/Main.hs`, `hwfl.cabal`, `model-catalog.json`; 2026-08-10
  pass focused on MCP client (`Mcp/Client`, `Runtime/Mcp`, `Host` mcp.*),
  `Exec` / `ProcGroup`, run-store locking, and agent human-gate promotion.
- **Method:** six parallel read-only reviews (2026-08-05) over disjoint module
  slices, plus a 2026-08-10 architecture-mapped pass with targeted deep reads
  and an executed MCP timeout-reuse probe against
  `test/fixtures/mcp/echo_server.py`. `.env` present but gitignored and
  untracked — no keys committed.
- **Status:** All Highs fixed or retracted (H-1; **H-8** fixed 2026-08-10).
  Medium open: **M-3**, **M-16**. **M-18** fixed 2026-08-12;
  **M-20** / **M-21** fixed 2026-08-10. Remaining Lows are hygiene — see table and
  [TASKS.md](TASKS.md).
  This report stays the durable source of truth for findings.
- **Repository:** `hwfl` — durable workflow runtime library. Markdown modules (L1) → typed ML kernel: checker + pure evaluator (L2) → CEK machine with snapshot/resume, FS sandbox, `exec.run` allowlist, `llm.*` provider, MCP stdio client, human gates (L3). Run state persists under `workspace/.hwfl/runs/<run-id>/{meta.json, snapshot.json, spans.jsonl, events.jsonl, transitions.jsonl}`.

## Severity legend

| Level    | Meaning                                                    |
| -------- | ---------------------------------------------------------- |
| **High** | Crash, security breach, or data loss on plausible input    |
| **Med**  | Bug on edge input, robustness gap, or latent security hole |
| **Low**  | Latent risk, hygiene, or design wart                       |

Each finding carries a **Verification** tag:

- `[Verified]` — cited code read directly during this analysis.
- `[Reported]` — identified by a parallel review with quoted evidence; spot-corroborated.

`[Verified]` is weaker than it looks: it certifies that the code was read, not
that the failure was reproduced. H-1 was `[Verified]` and still wrong, because
it assumed a library contract instead of executing it. Treat any security
finding as unconfirmed until a proof-of-concept has actually run.

---

## High

### H-1 — ~~Sandbox escape: `fs.write` / `fs.copy` follow symlinks out of the workspace~~ **RETRACTED — not reproducible**

- **Location:** `src/Hwfl/Runtime/Workspace.hs` (`writeTextFile`, `copyOneFile`)
- **Verification:** `[Verified]` → **Retracted** (2026-08-07), superseded by H-1a below.

The claim rested on "`canonicalizePath` **throws** on a dangling symlink (POSIX `realpath` ENOENT), so the `_ ->` fallback runs `BS.writeFile target`". **That premise is false.** `directory`'s `canonicalizePath` is not `realpath`: `attemptRealpathWith`/`realpathFurther` explicitly call `getSymbolicLinkTarget` on each unresolved segment and dereference dangling links, returning the resolved-but-nonexistent path. Measured on `directory-1.3.8.5`:

```
canon <ws>/dangling-out  =>  Right "/private/tmp/outside/missing.txt"
```

which is outside the root, so the old leaf check returned `SandboxErr`. Replaying the exact HEAD~1 logic against a dangling **and** a live out-of-workspace link:

```
fs.write through a DANGLING symlink  ->  Left "SandboxErr leaf"   (no file created outside)
fs.write through a LIVE symlink      ->  Left "SandboxErr leaf"   (outside file unchanged)
```

The `copyOneFile` half was also wrong. `System.Directory.copyFile` is `atomicCopyFileContents`: it opens a temp file in `takeDirectory dst` (the already-canonicalized parent, inside the root), copies, `copyPermissions`, then `renameFile tmp dst`. `rename(2)` never follows a symlink on the final component, so the destination link was *replaced* by a regular file inside the workspace:

```
fs.copy onto a DANGLING symlink  ->  Right ()  (no file outside; dst is now a regular file)
fs.copy onto a LIVE symlink      ->  Right ()  (outside file unchanged)
```

**Lesson for this report:** `[Verified]` meant "cited code read directly", not "failure reproduced". Security claims need an executed proof-of-concept, not a reading of the library's contract.

### H-1a — Sandbox escape: directories created outside the root before the containment check

- **Location:** `src/Hwfl/Runtime/Workspace.hs` (`writeTextFile`, `copyOneFile`, `movePath`, `mkdirPath`)
- **Verification:** `[Verified]` — reproduced. **Fixed** (2026-08-07)

The real ordering bug, found while disproving H-1. Every mutating op ran `createDirectoryIfMissing True parent` **and then** canonicalized and checked containment. With an in-workspace directory symlink `dirlink -> /tmp/evil`, `fs.mkdir("dirlink/escaped")` created `/tmp/evil/escaped` and only afterwards returned `SandboxErr`:

```
createDirectoryIfMissing <ws>/dirlink/escaped  =>  ()
  created outside?                             =>  True
```

- **Impact:** Attacker-chosen directory creation anywhere the process can write. No file contents escape (the leaf checks held), so this is a weaker primitive than H-1 claimed — but it is a genuine escape, and it is the same "create, then check" ordering mistake in four places.
- **Fix applied:** `ensureDirUnderRoot` walks the chain one component at a time from the canonical root, checking containment *before* each `createDirectory`. The cursor is canonical and inside the root at every step, so nothing can be created outside by construction. `writeTextFile` / `copyOneFile` / `movePath` / `mkdirPath` all go through it.

Hardening landed alongside (closes L-24):

- Write destinations open with `O_NOFOLLOW`; copies land via `rename`. Neither can be redirected by a link swapped in after the check, so the leaf TOCTOU is closed rather than narrowed. `ELOOP`/`EMLINK` is detected by `ioe_errno`, not by matching the locale-dependent `strerror` text.
- A leaf symlink is followed only when it resolves inside the workspace, making write symmetric with read; workspace-internal aliases stay usable.
- `fs.remove` unlinks a leaf symlink instead of following it. Previously `fs.remove` on a *directory* symlink canonicalized and then ran `removeDirectoryRecursive` on the **target** — silent data loss outside the sandbox, and the most damaging bug in this cluster. Not in the original report.
- `pathExists` / `statPath` agree: a symlink is an existing entry with `kind = "symlink"`, so `fs.copy` / `fs.move` cannot clobber one unnoticed.
- `fs.copy` keeps `copyFile`'s atomicity and access mode (set-uid/gid and sticky bits are dropped deliberately); a file-onto-file overwrite is no longer pre-removed, so the destination survives a failed copy.

### H-2 — No exception containment in the run loop; any IO/pure exception kills the process

- **Location:** `src/Hwfl/Runtime/Eval.hs:400` (`runHostOp`), `:623` (`llmChat`); `src/Hwfl/Runtime/Host.hs:984,1009,1029`; `app/Main.hs` (no top-level handler; only a stdin-EOF `catch` at `:440`)
- **Verification:** `[Verified]` — grep confirms zero `try`/`catch`/`bracket`/`finally` in `Eval.hs` and `Run.hs`. **Fixed** (2026-08-07)

The run loop has **no exception barrier**. `result <- runHostOp host op args` and `result <- ctx.rcHost.heProvider.llmChat req` run unguarded; only `Llm/Simple.hs:61` wraps `loadModelOrThrow`. `Main.hs` has no `SomeException` handler, so the CLI dies with a raw GHC exception — no `--json` envelope, no `OutcomeFailed`.

- **Impact:** Any provider throw, disk-full during snapshot persist (`Store.hs:337-355`), or pure exception (H-3, H-4) crashes the process. `snapshot.json` holds the **pre-exception machine**; resume re-executes from it, **duplicating already-applied side effects** (double `exec.run`, double LLM spend). Last host span stays open.
- **Fix applied:** Three barriers, all built on `Hwfl.Exception.trySync`, which contains synchronous exceptions but re-throws `SomeAsyncException`, `ExitCode`, `ThreadKilled`, `UserInterrupt` and `HeapOverflow` so Ctrl-C and cancellation still work:
  - `runHostOp` (`Host.hs`) reports a throw from any op as `HostErr "<op>: <message>"` — catchable by author `try`/`catch`, like every other host failure.
  - `safeLlmChat` (`Llm/Provider.hs`) turns an adapter throw into `OtherProviderError`; all four call sites (`llm.chat`, `llm.chat_messages`, `llm.object`, agent model round) use it, so a socket reset fails the round rather than the process.
  - `guardedStep` (`Eval.hs`) wraps every `stepMachine` call from `runUntilPause`. A crash below it becomes the new `InternalErr`, which is **not** `isCatchable`: the step aborted at an unknown point, so author code must not resume on top of it. Before returning, the barrier closes the spans that step opened (`SsError`) and persists the machine as `MsFailed`, so `snapshot.json` no longer holds a replayable pre-crash machine. Cleanup is itself wrapped, so a store that fails on the error path cannot mask the original exception.
- Plus a last-resort handler in `app/Main.hs`: anything escaping the CLI outside a run (loading, reporting) is printed as a normal `--json` error envelope with kind `InternalError` instead of a raw GHC exception. Raw `IOException` text still leaks through it for missing module / catalog files — that is M-7's job.
- **Not fixed here:** the *nested* branch machines (agent tool, `par`, `FrInvoke`) call `stepMachine` directly; a crash there propagates to the enclosing `runUntilPause` and fails the whole run. That is deliberate — an unknown-state crash must not be recovered into "this tool call failed, continue".

### H-3 — `jsonToValue` Double round-trip: silent integer corruption ≥ 2⁵³ and crash on huge magnitudes

- **Location:** `src/Hwfl/Json/Encode.hs:29-32`; reachable from `Host.hs:1045` (`llm.object`), `Agent.hs:372-374` (submit), `Agent.hs:676` (tool args), `Host.hs:704,800` (`meta.read_snapshot`/`read_spans`)
- **Verification:** `[Verified]` — **Fixed** (2026-08-07)

```haskell
Aeson.Number n ->
  let d = realToFrac n :: Double
      i = round d :: Integer
   in if fromIntegral i == d then VInt i else VFloat d
```

Every JSON number funnels through `Double`. An integer ≥ 2⁵³ (`9007199254740993`) rounds to `9007199254740992` — **silent corruption**, even though `VInt` is arbitrary-precision `Integer` (`fromIntegral i == d` cannot detect it). A magnitude ≥ ~1.8e308 (model emits `1e999`) makes `d` infinite and `round Infinity` throws an arithmetic exception — which, per H-2, escapes as a crash.

- **Impact:** Untrusted LLM output (tool arguments, submit payloads, `llm.object` results, snapshot/span reads) either corrupts integers silently or crashes the process.
- **Fix applied:** `jsonToValue` now uses `Scientific.floatingOrInteger`, so
  every mathematically integral JSON number becomes an arbitrary-precision
  `VInt`. Fractional values convert to `Double` exactly once and are rejected
  if that conversion is non-finite; the fallible conversion propagates through
  LLM object responses, agent submit/tool arguments, and meta-read values.

### H-4 — Non-finite floats from ordinary language code crash persist/encode

- **Location:** `src/Hwfl/Json/Encode.hs:43` (`VFloat d -> Aeson.Number (realToFrac d)`), `src/Hwfl/Runtime/Snapshot.hs:683` (`"v" .= d`), `src/Hwfl/Eval/Value.hs:225-229` (`renderFloat`); overflow source `src/Hwfl/Eval/Prelude.hs:169-170` (`num2` float ops)
- **Verification:** `[Verified]` (mechanism); **fixed 2026-08-07**

`1e308 * 10.0` produces `VFloat Infinity` — no NaN/Inf guard anywhere in the arithmetic builtins. The value then reaches Aeson via `realToFrac d :: Scientific` (or `renderFloat`'s `round d :: Integer`), both of which **throw on NaN/Infinity**. Any snapshot persist or `json.encode` of the value crashes the run (escapes per H-2).

- **Impact:** Float overflow → process crash with stale snapshot → duplicate side effects on resume.
- **Fix applied:** `finiteFloat` now rejects NaN/Infinity from float literals
  and arithmetic operations as `Trap`s, preventing invalid values from
  reaching snapshot persistence. `valueToJsonText`/`valueToAeson` and
  interpolation rendering are fallible and recursively reject a non-finite
  `VFloat` supplied by an internal caller; agent tool-result encoding reports
  that failure as a recoverable tool error rather than throwing.

### H-5 — `nextPow2` non-termination (DoS) on large budget values

- **Location:** `src/Hwfl/Runtime/Eval.hs:1610-1613` (`suggestExtraRounds`/`nextPow2`); reachable via snapshot `max_rounds`/`round` (`Snapshot.hs:341-347`) and `extendAgentMachine` wrap (`Eval.hs:1616-1624`)
- **Verification:** `[Verified]`; **fixed 2026-08-07**

```haskell
nextPow2 n = head [p | p <- map (2 ^) [(0 :: Int) ..], p >= n]
```

For `n > 2^62`, `2^63` overflows `Int` to `minBound` (negative); no element ever satisfies `p >= n`, so `head` scans the infinite list **forever**. `suggestExtraRounds` is called whenever an agent exhausts its budget. A crafted snapshot with `"max_rounds": 9223372036854775807` (or `--rounds` extension that wraps `agMaxRounds + extra` into that range) **hangs the single-threaded run loop**.

- **Impact:** DoS via crafted run state or a large config value.
- **Fix applied:** `nextPow2` now uses a bounded doubling search that saturates
  instead of wrapping. Exhaustion suggestions are capped to the remaining
  `Int` headroom (zero when no extension is representable), and extension
  rejects zero/negative values and checked-addition overflow. Source
  `max_rounds` rejects values outside positive `Int`; snapshot decoding rejects
  non-positive agent budgets and round counters.

### H-6 — Checker/runtime divergence: accepted programs trap at runtime

- **Location:** `src/Hwfl/Check/Infer.hs:389-395` (`f()` on non-Unit), `:398-404` (positional args zip-checked against record _fields_); runtime side `src/Hwfl/Eval/Pure.hs:113-133` (`bindParams`); host-op record stubs `src/Hwfl/Check/Prelude.hs:141-149`
- **Verification:** `[Verified]`; **fixed 2026-08** — empty application now
  rejects non-`Unit` domains; runtime supplies omitted `Unit` and packs
  positional/named record fields for a single record parameter. `fs.write`
  accepts the two positional arguments the checker validates.

1. `go ty []` — for `f() : Int -> Int`, when the domain isn't `Unit` it returns `Right ty` (the **function type itself**) instead of an error. `f()` typechecks; runtime applies `f` to zero args → `bindParams` arity `Trap`.
2. `applyPositional` — when `length args == length fields` it zips positional args against record fields: `f {a=1} {b=2}` for `fun (a: Int, b: Int)` checks each record against a _field_ type and accepts. Runtime `bindParams` binds `a := {a=1}` (a record where `Int` was promised) → downstream arithmetic traps. Same class: `fs.write("a.txt", "hi")` typechecks against the record stub `{path, text}`; the driver receives two positionals.

- **Impact:** The type checker promises `Int`/valid calls for programs that crash at runtime — checker soundness hole on ordinary author input.
- **Fix applied:** Align `applyPositional`/`applyNamed` with `bindParams` for
  empty/`Unit` calls, single-record packing, and `fs.write` positionals.
  Same-family residuals closed as **M-19** (record-domain host normalize,
  positional `fs.move` / `exec.run`, Unit thunks / alias packing).

### H-7 — Unsanitized run-id is joined into a filesystem path (library API)

- **Location:** `src/Hwfl/Runtime/Run.hs:373` (`maybe newRunId pure opts.roRunId`), `src/Hwfl/Runtime/Store.hs:192-194` (`openRunStore` → `T.unpack runId </>` + `createDirectoryIfMissing True`), `:183-186` (`openRunDir`)
- **Verification:** `[Verified]` — reproduced on the CLI. **Fixed** (2026-08-07)

`runTarget`/`resumeRun`/`approveRun`/… take the run-id verbatim and join it into `workspace/.hwfl/runs/<run-id>`, creating directories with `createDirectoryIfMissing True`. A run-id of `../../x` gives **arbitrary directory creation plus `meta.json`/`snapshot.json` read/write outside the workspace**. The CLI only exposes run-id positionally (operator-trusted), but the library API — the control-plane surface per `docs/architecture.md` — accepts caller-supplied ids.

Related: **explicit run-id reuse merges runs** (`Run.hs:373-375`, `Store.hs:284-289`) — no existence check; old `snapshot.json`/`spans.jsonl` survive while `meta.json` is atomically clobbered and the seq resets to 0, so a crash before first persist leaves new meta + previous run's machine (same project hash) → duplicated execution and mixed spans.

- **Fix applied:** `validateRunId` in `Store.hs` accepts only a single portable path component (`A-Za-z0-9._-`, no leading `.`, ≤ 128 chars) and every id→path mapping goes through `runDirFor`, which validates first. `hwfl resume . ../../pwned` now prints `config: run id must not start with '.'` and creates nothing.

  The number of id→path entry points shrank with it: `openRunStore` / `tryOpenRunStore` are gone; a start goes through `createRun` (validate → `createDirectory`, so reuse loses the check/create race) and a continue goes through `openRun` (invalid or unknown id → `Nothing`). Resume no longer materialises a directory for an id it cannot open; the failure paths take a pure, non-creating handle (`runStoreHandle`) or a detached one that drops writes and reads empty.

- **Deviation:** reuse of an existing run id is rejected **unconditionally**, with no "explicitly intended" opt-in. Starting a run into a live run directory has no correct semantics — old snapshot / spans survive while meta is replaced and the sequence restarts, which is exactly the corruption above — so continuing an existing run stays the job of resume / step / approve.

### H-8 — ~~MCP spawn trust weaker than `exec.run` and than [spec/13-mcp.md](spec/13-mcp.md) §3~~ **Fixed**

- **Location:** `src/Hwfl/Project.hs` (`McpPolicy` / `validateMcpPolicy`);
  `src/Hwfl/Runtime/Mcp.hs` (`resolveSpawnSpec`)
- **Verification:** `[Verified]` — code + dogfood configs. **Fixed** (2026-08-10)

Spec §3 requires MCP `command` to be an executable **basename** with the
same trust model as `exec.allow`, and absolute `cwd` “only if policy
allows.” Implementation now matches:

1. **`mcp.allow`** — every `mcp.servers.<id>.command` must be a bare
   basename listed in `mcp.allow` (fail closed at `project.json` load and
   again at spawn).
2. **`mcp.allow_absolute_cwd`** — default `false`; absolute `cwd` rejected
   unless opted in.
3. Dogfood configs (`examples/story-writer`, `examples/real-story-writer`)
   set `"allow": ["bash"]`.

Optional first-spawn confirm (mirroring `exec.confirm`) was not taken —
operator consent is the allowlist at load time; MCP commands are not
chosen by workflow code the way `exec.run` programs are.

- **Impact (pre-fix):** Arbitrary process execution as the hwfl user when
  loading an untrusted project tree.
- **Fix applied:** Dedicated MCP allow policy + basename / cwd gates in
  `validateMcpPolicy` and `resolveSpawnSpec`.

---

## Medium

### M-1 — `llm.object` response schema validation

- **Location:** `src/Hwfl/Runtime/Host.hs` (`doLlmObject` /
  `decodeJsonObject`); `src/Hwfl/Json/Validate.hs`
- **Verification:** **Fixed** (2026-08-07)

`llm.object` now validates decoded provider JSON with
`validateAgainstSchema` before `jsonToValue`, matching the existing
`llm.agent_object` submit boundary. A model response such as
`{"score": "high"}` for `schema({score: Int})` returns a normal `HostErr`
rather than reaching user code as a `VString` where the checker promised
`Int`.

### M-2 — Redaction gaps: embedded, short, and oddly-keyed secrets leak to events and stderr

- **Location:** `src/Hwfl/Obs/Redact.hs:53-86`; `src/Hwfl/Obs/Stream.hs:143-147` (unredacted `debugLog` of LLM deltas); `src/Hwfl/Obs/Observer.hs:64` (raw stderr); `Run.hs:626` (host-op logs unredacted to stderr)
- **Verification:** **Fixed** (2026-08-07)

Sensitive keys are now normalized before matching (`private_key`, `passphrase`,
`pwd`, and `pem` included). Text redaction handles JSON embedded in strings,
common key/JWT/hex credential forms, and PEM blocks. Streaming event fields are
redacted before durable append; the stderr observer and host-progress logger
also redact as a final boundary. This is defence in depth: only `VSecret`
taint can soundly protect arbitrary short plaintext.

### M-3 — Skill bodies injected verbatim into the system prompt (prompt injection with agent powers)

- **Location:** `src/Hwfl/Runtime/Skills.hs` (`instructionInjectionText`)
- **Verification:** `[Reported]` — confirmed still open (2026-08-10)

Skill markdown bodies are concatenated into the system prompt each round, and skills are loaded **at the model's own request**. Content is project-authored today, but a third-party skill (e.g. cloned from a repo) can instruct the model with tool-calling authority. No trust boundary or instruction-delimiting.

### M-4 — Fixed: `requestToTurns` preserves all `RoleSystem` messages

- **Location:** `src/Hwfl/Llm/Simple.hs`
- **Verification:** **Fixed** (2026-08-08)

Message-path requests join every non-empty system text (`chatSystem` when not
already the Host-prepended head, then each in-list `RoleSystem`) with `\n\n`
into llm-simple's single `grSystemPrompt`. User/assistant order is unchanged;
the agent `chatTurns` path still uses `chatSystem` alone.

### M-5 — `fs.find`/`fs.grep` descend directory symlinks without canonicalization or cycle checks

- **Location:** `src/Hwfl/Runtime/Workspace.hs` (`walkFiles`)
- **Verification:** **Fixed** (2026-08-07)

The shared walker now classifies each entry with `lstat` semantics before
testing whether it is a directory, so directory symlinks are leaves and are
never descended. Each real directory is canonicalized and checked below the
canonical workspace root before listing; a visited-canonical-directory set
also terminates any future alias cycle. Regression coverage verifies external,
internal-alias, and self-loop directory links for both `fs.find` and
glob-less `fs.grep`.

### M-6 — Fixed: `exec.run` stream caps, process-group kill, policy numerics

- **Location:** `src/Hwfl/Runtime/Exec.hs`, `src/Hwfl/Project.hs`
- **Verification:** **Fixed** (2026-08-08)

Stdout/stderr are read through capped pipe readers that retain at most
`max_output_bytes` and drain the rest, so a noisy child cannot OOM the host.
Children spawn in a new process group; on timeout the group receives SIGTERM
then SIGKILL, and any bytes already captured are returned with
`timed_out = true`. `timeout_ms` / `max_output_bytes` are validated in
`project.json` parse and again in `runExec` (positive timeout; non-negative
cap; no `Int` overflow on µs conversion).

### M-7 — Fixed: module / project / catalog reads return stable diagnostics

- **Location:** `src/Hwfl/SafeIO.hs`, `Parse/Load.hs`, `Project.hs`, `Llm/Pricing.hs`
- **Verification:** `[Fixed]` (2026-08-07)

Module source now reads bytes and decodes with explicit UTF-8. Read failures
and invalid byte sequences become stable English diagnostics at `1:1`, so the
existing `--json` diagnostic envelope is preserved. `project.json` and module
discovery reads use the same contained I/O layer; an unreadable catalog reaches
the run API as `ConfigErr`, while a missing catalog remains optional for mock
runs. Existing malformed catalogs now report configuration failure rather than
silently producing zero pricing.

### M-8 — Resource exhaustion on untrusted input (parse/eval/check)

- **Locations:** YAML alias bomb `src/Hwfl/Parse/Frontmatter.hs` / `YamlSafe.hs`; parser depth `Parse/Expr.hs`, `Parse/Type.hs`; digit literals `Parse/Pat.hs`, `Parse/Lexer.hs`; pure evaluator `Eval/Pure.hs`; machine frames `Runtime/Eval.hs` crunch; type-alias expansion `Check/Env.hs`
- **Verification:** **Fixed** (2026-08-08)

Frontmatter YAML is event-validated before aeson decode: aliases are rejected and
nesting / node count are capped. Expression and type parsers carry a nesting
counter (`maxParseDepth`). Integer / float digit runs use linear parsers with a
length ceiling; non-finite floats fail at parse time. Pure `eval` is
fuel-bounded; CEK crunch also enforces `maxMachineFrames`. `resolveType` memoizes
alias expansion so DAG-shaped aliases no longer expand exponentially.

### M-9 — YAML duplicate keys silently last-wins

- **Location:** `src/Hwfl/Parse/YamlSafe.hs` (via `Frontmatter.hs`)
- **Verification:** **Fixed** (2026-08-08)

Libyaml event validation rejects duplicate mapping keys (including nested
`inputs` / `outputs` / `skill` maps) before aeson decode. Duplicate keys
surface as frontmatter diagnostics instead of silent last-wins overrides.
Regression coverage in `FrontmatterSpec`.

### M-10 — Effects of a top-level fun called through a let-alias are lost

- **Location:** `src/Hwfl/Check/Effects.hs`
- **Verification:** **Fixed** (2026-08-08)

`ELet` now binds the RHS callee residual into `EffEnv` and, for alias-shaped
RHSs (`EVar` / import / projection), extends `TypeEnv` so
`effectsReleasedByApp` can resolve the alias. `let g = f in g()` charges `f`'s
effects; a pure let-shadow of an effectful top-level name does not. Regression
coverage in `ModuleSpec`.

### M-11 — `TOption` fields forced `required`; `TSecret` flattened to inner schema

- **Location:** `src/Hwfl/Check/Schema.hs`, `src/Hwfl/Json/Encode.hs`
- **Verification:** **Fixed** (2026-08-08; (b) 2026-08-07)

(a) Record schemas omit `Option` fields from `required` (aliases resolved).
`schema(Option<T>)` carries `x-hwfl-option`; decode maps JSON `null` and
absent optional fields to `None`, and present values to `Some(_)`. Language
constructors `None` / `Some(e)` and typed `match` arms land on `VVariant`.
(b) `TSecret` emits an internal schema annotation. Provider-bound schemas
strip it, while `llm.object` and agent submit decode structurally and restore
`VSecret` at every annotated node.

### M-12 — Par branch agent-budget exhaustion misclassified as "no progress"

- **Location:** `src/Hwfl/Runtime/Eval.hs` (`pickRunnable`, `stepParWith`, `extendAgentMachine`)
- **Verification:** **Fixed** (2026-08-08)

`PauseAwaitingAgent` and `PauseCrashRecovery` are not runnable in `par`.
Agent budget exhaustion absorbs like human gates (`ParSlotAwaitingAgent` /
`pjsAgentQueue`), drains the pool, and surfaces root `awaiting_extend`.
`extendAgentMachine` bumps the tagged branch's `agMaxRounds` and resumes
scheduling. Regression: `par` + `max_rounds = 1` soft-lands, bare resume stays
paused, `extend` completes the join.

### M-13 — Failure states are not durable; meta/snapshot status divergence

- **Location:** `src/Hwfl/Runtime/Eval.hs:247`, `src/Hwfl/Runtime/Run.hs:497-516`
- **Verification:** **Fixed** (2026-08-07)

`runUntilPause` now persists the failed root machine on its ordinary `Left err`
path before `finalizeOutcome` updates `meta.json`. The snapshot status and
embedded machine are both `MsFailed`, so meta and snapshot report `"failed"`
after finalization and resume returns the terminal failure without replaying
the step. Regression coverage uses an ordinary division-by-zero evaluator
trap, rather than an exception or host-operation failure path.

### M-14 — `splitSentences` drops the final sentence

- **Location:** `src/Hwfl/Text/Corpus.hs:101-106`
- **Verification:** **Fixed** (2026-08-07)

`consume [] acc cur` now appends a non-blank trailing `cur` after the completed
sentences. Regression coverage includes terminated and unterminated final
sentences, a single fragment, and whitespace-only input.

### M-15 — Fixed with M-7: catalog decode failures are surfaced

- **Location:** `src/Hwfl/Llm/Pricing.hs`
- **Verification:** `[Fixed]` (2026-08-07)

An existing catalog now returns a configuration error if it cannot be decoded;
it no longer becomes `emptyModelPricing`. Missing catalogs remain intentionally
optional for mock-provider runs.

### M-16 — Concurrent approve/choose/reply on one run: no lock, double execution, torn snapshot

- **Location:** `src/Hwfl/Runtime/Store.hs` (shared `snapshot.json.tmp` + rename), `src/Hwfl/Runtime/Run.hs` (`approveRun`/`chooseRun`/`replyRun` run the full continuation)
- **Verification:** `[Reported]` — confirmed still open (2026-08-10 code read)

Two processes approving the same paused run both run the full continuation (double LLM spend, double `exec.run` / MCP side effects) and both write `snapshot.json.tmp` then rename — interleaved writes can tear `snapshot.json` and brick resume. `atomicEncodeFile` uses a **fixed** sibling name (`path <> ".tmp"`), so two writers clobber the same temp file before rename. Multi-process locking is explicitly deferred in `docs/TASKS.md`; this notes the concrete failure mode when it bites (parallel lab processes).

- **Suggested fix:** per-run exclusive lock (`flock` / lockfile) around open→step→persist; unique tmp names (`snapshot.json.<pid>.<nonce>.tmp`) as defence in depth.

### M-17 — Provider errors: finish-reason ignored; `--debug` string-sniffing for span status

- **Verification:** **Fixed** (2026-08-08).
- **Fix applied:** `completeToolCall` takes a structured `ToolOk` /
  `ToolErr` outcome so tool span status is set at the call site, not by
  sniffing result text. Provider close attrs include `finish_reason`;
  `FinishLength` fails the agent round as `SsError`; finish/tool_calls
  mismatches are recorded as `finish_reason_mismatch` without changing
  content-based control flow.

### M-18 — ~~Project hash includes full prose bodies → resume falsely reports "stale project"~~ **Fixed**

- **Location:** `src/Hwfl/Project.hs` (`projectHashForModules`)
- **Verification:** `[Reported]` — **Fixed** (2026-08-12)

Before the fix, `projectHashForModules` folded `show m` over each
`LoadedModule` (including `lmProseBody`, `lmSections`, frontmatter, and body
AST) into a weak `Int` polynomial hash. Any whitespace/prose edit changed the
hash and blocked resume with `ConfigErr "stale project: hash mismatch"`.

- **Fix applied:** hash module identity, frontmatter, and code-fence body AST
  with SHA-256; exclude prose bodies, raw sections, and schema docs. The
  digest is truncated to the existing 16-character run metadata field.

### M-19 — H-6 residuals: checker still accepts some runtime-failing call shapes

- **Verification:** **Fixed** (2026-08-07).
- **Fix applied:** record-domain host calls normalize a single positional record
  to named fields before dispatch; `fs.move` and `exec.run` also accept their
  checked positional forms. `bindParams` unpacks a lone record for
  multi-parameter functions. Runtime function tables resolve parameter aliases
  recursively (including local lambdas), and a sole bare parameter denotes a
  `Unit` thunk. Regression coverage executes positional/record host calls and
  aliased Unit/record calls through the machine.

### M-20 — ~~MCP request timeout leaves a wedged cached connection~~ **FIXED**

- **Location:** `src/Hwfl/Mcp/Client.hs` (`sendRequest` + `System.Timeout.timeout`
  + `awaitResponse`); `src/Hwfl/Runtime/Mcp.hs` (`getMcpConnection` /
  `invalidateMcpConnection`); `src/Hwfl/Runtime/Host.hs` (`doMcpCall` /
  `doMcpTools`)
- **Verification:** `[Verified]` — executed probe (2026-08-10) against
  `test/fixtures/mcp/echo_server.py`; regression in `McpSpec` (2026-08-10)

On per-request timeout the client returned `Left "… request timed out"` but
**kept** the `McpConnection` in `meConnections`. Timeout does **not**
cancel server-side work: the stdio server remains busy inside the slow
`tools/call`. Production would issue the next `mcp.*` on the same cached
pipe.

Measured (before fix):

```
timeout_ms = 200; tool sleep_ms = 1500
r1 (slow)          -> Left "request timed out"
r2 (fast, immediate) -> Left "request timed out"   -- server still on r1
wait 2s
r3 (fast)          -> Right McpCallOk …            -- recovers after drain
```

So an immediate retry (the normal next host op in a workflow/agent loop)
failed even for a fast tool. Framing recovered after the slow call
finished in this probe (mismatched-id skip path), but `timeout` still
async-interrupts `hGetLine`, which remains a latent NDJSON framing risk
on other platforms/loads. Dead/crashed connections were likewise never
evicted mid-run.

Additionally: the timed-out server call may still **complete side
effects** after the client has reported failure — at-least-once /
timeout ambiguity for non-idempotent MCP tools (unchanged; reconnect
cannot make a non-idempotent tool safe).

- **Impact:** Mid-run MCP storms of timeouts after one slow tool; agent
  loops soft-land or abort; possible duplicate external effects.
- **Fix (2026-08-10):** On transport `Left` from `callMcpTool` /
  `listMcpTools`, `invalidateMcpConnection` drops the server from the
  registry and `closeMcpConnection` (process-group kill). The next
  `getMcpConnection` reconnects lazily. Regression:
  timeout → catch → immediate fast call succeeds.

### M-21 — ~~`exec.run` stdout/stderr reader threads can deadlock the parent~~ **Fixed**

- **Location:** `src/Hwfl/Runtime/Exec.hs` (`runCapped`, `readCapped`)
- **Verification:** `[Reported]` → **Fixed** (2026-08-10); regression in `ExecSpec`

```haskell
_ <- forkIO $ putMVar outVar =<< readCapped cap (getStdout p)
_ <- forkIO $ putMVar errVar =<< readCapped cap (getStderr p)
…
out <- takeMVar outVar
err <- takeMVar errVar
```

`readCapped`'s main loop did not catch `IOException` from `hGetSome`.
If a reader thread died before `putMVar` (broken pipe after
`killProcessGroup`, unexpected IO error), the parent blocked forever on
`takeMVar`. Drain path after the cap *did* catch IO errors; the primary
read loop did not. Timeout path was the most likely trigger (group kill
closes pipes while readers run).

- **Impact:** Rare hard hang of the hwfl process on `exec.run` timeout /
  spawn teardown — requires kill -9; run snapshot may be mid-transition.
- **Fix:** `forkFinally` readers always `putMVar` (empty bytes on failure);
  `readCapped` main loop `try`s `hGetSome` like drain. Regressions:
  throwing `forkFinally` reader contract, timeout under stdout flood
  within a wall-clock bound.
---

## Low

| ID   | Location                                                     | Issue                                                                                                                                                                                  |
| ---- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L-1  | `Eval.hs`, `Trace.hs`                                        | **Fixed** (2026-08): `failAgent` sole closer for agent_round; `closeSpan` idempotent (no double cost / duplicate close).                                                              |
| L-2  | `Eval.hs`, `Trace.hs`                                        | **Fixed** (2026-08): LIFO unwind on non-head close; `abortOrCatch` closes discarded `FrRegion` / `FrInvoke` spans.                                                                   |
| L-3  | `Snapshot.hs`                                                | **Fixed** (2026-08): `parsePauseReason` fails closed (no `PauseExplicit` fallback); `snapshot_format` must equal `currentSnapshotFormat`.                                              |
| L-4  | `Store.hs:336-355,373-380`                                   | No fsync anywhere (tmp + rename only; spans/events plain append). Crash-safe, not power-loss-safe; power loss can lose the rename or persist a torn file → run unrecoverable.          |
| L-5  | `Parse/Expr.hs`                                              | **Fixed** (2026-08): tight `a/b` is QName; spaced `a / b` is division.                                                                                                                  |
| L-6  | `Parse/Expr.hs`                                              | **Fixed** (2026-08): implicit let body only when it starts on a later line; `let x = a b` is a parse error.                                                                              |
| L-7  | `Parse/Section.hs`                                           | **Fixed** (2026-08): empty / duplicate H2/H3 slugs rejected at load and `md.sections` (ASCII strip unchanged; collisions fail closed).                                                  |
| L-8  | `Check/Project.hs`                                           | **Fixed** (2026-08): `findCycle` DFS over remaining nodes with backtracking; reports a closed cycle (not a first-edge dead-end path).                                                  |
| L-9  | `Parse/Markdown.hs:87-100`                                   | Frontmatter requires `---` on line 1 and `T.strip` doesn't remove U+FEFF: BOM or leading blank hides frontmatter; BOM inside a fence is a lexer error.                                 |
| L-10 | `Frontmatter.hs:97-146`                                      | All frontmatter errors pinned at `Pos 1 1`; YAML's own line/col info discarded.                                                                                                        |
| L-11 | `Frontmatter.hs:90`                                          | **Fixed** (2026-08): `parseTags` rejects non-string array entries (no silent drop).                                                                                                    |
| L-12 | `Frontmatter.hs:34,186`                                      | `qnameFromText` unvalidated (`""`, `"a//b"`, `"/x"`, `".."` accepted); caught downstream with confusing messages. No traversal risk (index-only resolution).                           |
| L-13 | `Cli/Args.hs`, `Runtime/Error.hs`                            | **Fixed** (2026-08): `wantsJson` skips value-taking flag args; `--` end-of-options for dash paths; `StaleProjectErr` + `runtimeExitCode` (no substring match).                        |
| L-14 | `Parse/Expr.hs`                                              | **Fixed** (2026-08): `&&` / `\|\|` desugar to `if` so evaluation short-circuits.                                                                                                         |
| L-15 | `Json/Encode.hs`                                             | **Fixed** (2026-08): nullary variants encode as `{"tag":…}` (same tagged shape as payload); Option Some/None unchanged. Schema-free decode stays a record, never `VString`.          |
| L-16 | `Check/Infer.hs`, `Check/Env.hs`, `Json/Encode.hs`           | **Fixed** (2026-08): duplicate record fields rejected at check; `json.encode` errors on duplicate keys.                                                                                |
| L-17 | `Check/Prelude.hs:360`, `Infer.hs:736-745,770-773`           | **Fixed** (2026-08): curried `obs.span("n")(thunk)` now returns the thunk body type, matching the two-argument form; regression in `Obs.SpanSpec`. |
| L-18 | `Check/Module.hs`                                            | **Fixed** (2026-08): example input values validated vs frontmatter `TypeExpr` (JSON Schema); CLI `--example <name>`.                                                                  |
| L-19 | `Agent.hs`, `Snapshot.hs`                                    | **Fixed** with H-5: source/snapshot `max_rounds` validated; extension uses checked add (no wrap).                                                                                      |
| L-20 | `Runtime/Ignore.hs:69-105`                                   | `isIgnored` checks hidden segments before rules, so `!.env` can never un-ignore a hidden name — deviates from gitignore semantics.                                                     |
| L-21 | `Runtime/Ignore.hs:168-181`                                  | `globMatch` naive backtracking (`any (go ps) (tails xs)`) — exponential on many-`*` rules vs long paths.                                                                               |
| L-22 | `Workspace.hs` `matchPat`                                    | **Fixed** (2026-08): `fs.find` / `fs.grep` extension globs compare ASCII case-insensitively.                                                                                          |
| L-23 | `Obs/Stream.hs:86-110`                                       | `appendText` read-modify-write not atomic; concurrent `onChunk` calls could drop text (single-threaded in practice).                                                                   |
| L-24 | `Workspace.hs` write/copy/remove                             | **Fixed** with H-1a: `O_NOFOLLOW` writes / `rename` copies close the leaf TOCTOU; `removePath` unlinks leaf symlinks.                                                                  |
| L-25 | `Parse/Section.hs:55-58,66-70`                               | `headings !! j` comprehension + fence rescan are O(n²) on large prose modules.                                                                                                         |
| L-26 | `Eval.hs` agent tool promote (`confirmOf` / `choiceOf` / `askOf`) | Agent nested-tool pause promotion discards `PauseAwaitingConfirm c` (etc.) and re-derives via `confirmOf bm'`, which invents an empty request if `mCurrent` mismatches. `FrInvoke` correctly threads `c`. Fail closed instead of synthesizing defaults. |
| L-27 | `Runtime/Eval.hs` (~3.2k), `Run.hs` (~1.5k), `Host.hs` (~1.3k) | Mega-modules concentrate interpreter / lifecycle / host dispatch — high review cost and regression risk. Split along Step / Agent / Par / HostApply and continue-paused helpers when touching the area. |

---

## Verified solid (do not re-report)

- **Read-path sandbox** — `resolvePath` (lexical `..`/absolute rejection) + `resolveContainedPath` (canonicalize + root-prefix) correctly block `..`, absolute, and symlink escapes for read/list/remove/stat/read_slice/edit/patch; null bytes surface as caught `IOException` → `HostErr`, never an escape.
- **`exec.run` policy** — bare-basename-only (no `/`), allowlist gates the binary, `setEnv` replaces the whole environment with only `exec.env` keys (no parent-env leakage), confirm default `True`, stdout/stderr captured via capped pipes (never leaks to terminal), process-group SIGTERM/SIGKILL on timeout with partial capture. Defaults are safe: `allow`/`env` default to `[]`.
- **`mcp.*` spawn policy (H-8)** — `mcp.allow` basename allowlist; absolute `cwd` only with `mcp.allow_absolute_cwd`; validated at load and spawn.
- **MCP teardown on driver exit** — `startRun` / resume-family paths use `finally` + `closeMcpEnv` (process-group kill). Mid-run timeout/reconnect is **M-20** (fixed).
- **MCP `bind` merge** — `mergeMcpBindArgs` lets bind win over model args; `stripBindFromSchema` removes bound keys from advertised schemas.
- **Corrupt-snapshot handling** — all parser `fail` sites (`Snapshot.hs:571-574`, `:821`, `:829-832`, …) are contained by `parseEither`; corrupt `snapshot.json`/`meta.json` → clean `ConfigErr "missing meta.json or snapshot.json"`, never a crash or state corruption. Project-hash check refuses stale-project resume.
- **Division by zero** — `div2` (`Eval/Prelude.hs:173-177`) guards **both** `Int` and `Float` zero divisors with `Trap`. _One review claimed Int div-by-zero was unguarded; direct read shows it is guarded — corrected here to prevent re-reporting._ `/` routes `BDiv → div2`.
- **Alias cycle detection** — `resolveAliasDef`/`resolveTypeFrom` stack-seeded, self-/mutual-/deep cycles all produce `AliasCycle`; `DuplicateType`/`DuplicateFun` cover redecls.
- **Secrets in snapshots** — `VSecret` persists as `"[REDACTED]"` (`Snapshot.hs:715-716`); span attrs redacted at write time.
- **Run-id auto-generation** — wall-clock second + 64-bit hex nonce (`Run.hs:1237-1241`); collision-resistant; hazard was only explicit reuse (H-7, fixed).
- **Lexer/parser core** — `tripleString` safe (megaparsec `tokens` restores state), `attachSourcePos errorOffset` correct, unterminated strings/comments give clean EOF diagnostics, position seeding consistent; no reachable unguarded `head`/`fromJust`/`read` on CLI input; `last xs` sites guarded.
- **Torn-line tolerance** — spans/events/transitions readers use `mapMaybe decode`; torn trailing lines are skipped.
- **Cooperative `par`** — host transitions are still single-threaded (concurrent host IO deferred in TASKS); no OS-level machine data race today. MCP `mcLock` anticipates future concurrent `par`.

---

## Recommended fix order

**Completed (2026-08):** all original Highs (H-1a–H-7; H-1 retracted);
Medium except M-3 / M-16; selected Lows (L-1–3, L-5–8, L-11,
L-13–16, L-19, L-22, L-24). See
[log/archive/tasks-2026-08.md](log/archive/tasks-2026-08.md).

**Open after 2026-08-10 MCP follow-up (priority):**

1. **M-16** — multi-process run-store locking (when parallel lab
   processes share a run dir).
2. **M-3** — skill-body prompt trust (when third-party skills matter).
3. Remaining **Lows** opportunistically (L-4, L-9–10, L-12, L-20–21,
   L-23, L-25–27 — fsync, CLI, ignore/glob, confirmOf,
   module splits, …).

**Completed same day:** **H-8** MCP command/cwd allowlist; **M-20**
MCP timeout reconnect; **M-21** `exec.run` reader `forkFinally`.

Agent context L1+L2 (heuristic) shipped. Active product work: agent
substrate (MCP dogfood / git / terminals). See [STATUS.md](STATUS.md).

---

## Method appendix

- **Pass 1 (map + sweep):** repo layout, `docs/STATUS.md`/`TASKS.md`/`architecture.md`; grep sweeps for `error`/`undefined`/`fromJust`, partial list functions, `unsafe*`/`trace`/`TODO`.
- **Pass 2 (deep reads):** six parallel read-only scouts over disjoint slices — runtime core, host boundary, LLM+agent, CLI/driver, parser/AST, checker/eval — each returning `path:line`-cited findings with severity.
- **Pass 3 (verification):** every High claim re-read directly; the one conflicting scout claim (Int div-by-zero) resolved against source (guarded); `cabal build` up to date; `.env` untracked (gitignored).
- **Pass 4 (2026-08-10):** architecture-mapped review of MCP stdio client,
  `Runtime/Mcp` registry, `Exec`/`ProcGroup`, store atomic rename, agent
  human-gate promotion. Executed MCP timeout→reuse probe (r2 timeout,
  r3 ok after wait). Spec §3 allowlist gap filed as H-8 (fixed same day).
  Coverage extended to post-audit MCP modules; prior open status
  reconfirmed for M-3 / M-16. M-18 was fixed in the subsequent
  implementation pass.
- **Coverage:** all `src/Hwfl/**` modules in initial pass; 2026-08-10
  focused on MCP / Exec / Store / Eval human-gate paths.
  `app/Main.hs`, `hwfl.cabal`, dogfood `project.json` included.
