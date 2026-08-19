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
  **M-20** / **M-21** fixed 2026-08-10. **L-20** / **L-26** fixed
  2026-08. Remaining Lows are hygiene — see table and
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

| ID | Summary | Status |
|----|---------|--------|
| H-1 | ~~Sandbox escape: `fs.write`/`fs.copy` follow symlinks out of workspace~~ | **Retracted** 2026-08-07 — `canonicalizePath` resolves dangling links; leaf check held. Lesson: `[Verified]` ≠ reproduced. |
| H-1a | Sandbox escape: directories created outside root before containment check (`writeTextFile`, `copyOneFile`, `movePath`, `mkdirPath`) | **Fixed** 2026-08-07 — `ensureDirUnderRoot` walks chain pre-creation; `O_NOFOLLOW` writes + `rename` copies close leaf TOCTOU; `fs.remove` unlinks leaf symlinks. |
| H-2 | No exception containment in run loop; any IO/pure exception kills the process | **Fixed** 2026-08-07 — `trySync` barriers in `runHostOp`, `safeLlmChat`, `guardedStep`; last-resort handler in `Main.hs`. |
| H-3 | `jsonToValue` Double round-trip: silent integer corruption ≥ 2⁵³, crash on huge magnitudes | **Fixed** 2026-08-07 — `Scientific.floatingOrInteger`; non-finite conversion rejected. |
| H-4 | Non-finite floats from ordinary language code crash persist/encode | **Fixed** 2026-08-07 — `finiteFloat` rejects NaN/Infinity from literals and arithmetic as `Trap`s; encode/interpolate fallible. |
| H-5 | `nextPow2` non-termination (DoS) on large budget values | **Fixed** 2026-08-07 — bounded doubling with saturation; `max_rounds` validated at source and snapshot decode. |
| H-6 | Checker/runtime divergence: accepted programs trap at runtime (`f()` on non-Unit, positional args vs record fields) | **Fixed** 2026-08 — `applyPositional`/`applyNamed` aligned with `bindParams`; `fs.write` positionals accepted. |
| H-7 | Unsanitized run-id joined into filesystem path (library API) | **Fixed** 2026-08-07 — `validateRunId` (portable basename, ≤128 chars); all id→path through `runDirFor`; reuse unconditionally rejected. |
| H-8 | MCP spawn trust weaker than `exec.run` and spec §3 | **Fixed** 2026-08-10 — `mcp.allow` basename allowlist; `mcp.allow_absolute_cwd` gate; validated at load and spawn. |

---

## Medium

### M-3 — Skill bodies injected verbatim into the system prompt (prompt injection with agent powers)

- **Location:** `src/Hwfl/Runtime/Skills.hs` (`instructionInjectionText`)
- **Verification:** `[Reported]` — confirmed still open (2026-08-10)

Skill markdown bodies are concatenated into the system prompt each round, and
skills are loaded **at the model's own request**. Content is project-authored
today, but a third-party skill (e.g. cloned from a repo) can instruct the model
with tool-calling authority. No trust boundary or instruction-delimiting.

### M-16 — Concurrent approve/choose/reply on one run: no lock, double execution, torn snapshot

- **Location:** `src/Hwfl/Runtime/Store.hs` (shared `snapshot.json.tmp` + rename), `src/Hwfl/Runtime/Run.hs`
- **Verification:** `[Reported]` — confirmed still open (2026-08-10 code read)

Two processes approving the same paused run both run the full continuation
(double LLM spend, double `exec.run` / MCP side effects) and both write
`snapshot.json.tmp` then rename — interleaved writes can tear `snapshot.json`
and brick resume. `atomicEncodeFile` uses a **fixed** sibling name, so two
writers clobber the same temp file before rename. Multi-process locking is
explicitly deferred in `docs/TASKS.md`.

- **Suggested fix:** per-run exclusive lock (`flock` / lockfile) around
  open→step→persist; unique tmp names (`snapshot.json.<pid>.<nonce>.tmp`) as
  defence in depth.

### Resolved Mediums

| ID | Summary | Status |
|----|---------|--------|
| M-1 | `llm.object` response schema validation missing | **Fixed** 2026-08-07 |
| M-2 | Redaction gaps: embedded, short, and oddly-keyed secrets leak to events/stderr | **Fixed** 2026-08-07 |
| M-4 | `requestToTurns` drops non-head `RoleSystem` messages | **Fixed** 2026-08-08 |
| M-5 | `fs.find`/`fs.grep` descend directory symlinks without canonicalization or cycle checks | **Fixed** 2026-08-07 |
| M-6 | `exec.run` stream caps, process-group kill, policy numerics | **Fixed** 2026-08-08 |
| M-7 | Module / project / catalog reads return raw IO errors instead of stable diagnostics | **Fixed** 2026-08-07 |
| M-8 | Resource exhaustion on untrusted input (YAML alias bomb, parse depth, fuel, frames, alias expansion) | **Fixed** 2026-08-08 |
| M-9 | YAML duplicate keys silently last-wins | **Fixed** 2026-08-08 |
| M-10 | Effects of a top-level fun called through a let-alias are lost | **Fixed** 2026-08-08 |
| M-11 | `TOption` fields forced `required`; `TSecret` flattened to inner schema | **Fixed** 2026-08-08 |
| M-12 | Par branch agent-budget exhaustion misclassified as "no progress" | **Fixed** 2026-08-08 |
| M-13 | Failure states not durable; meta/snapshot status divergence | **Fixed** 2026-08-07 |
| M-14 | `splitSentences` drops the final sentence | **Fixed** 2026-08-07 |
| M-15 | Catalog decode failures silently produce empty pricing | **Fixed** 2026-08-07 (with M-7) |
| M-17 | Provider errors: finish-reason ignored; `--debug` string-sniffing for span status | **Fixed** 2026-08-08 |
| M-18 | Project hash includes full prose bodies → resume falsely reports "stale project" | **Fixed** 2026-08-12 — SHA-256 over identity + frontmatter + code AST only |
| M-19 | H-6 residuals: checker still accepts some runtime-failing call shapes | **Fixed** 2026-08-07 |
| M-20 | MCP request timeout leaves a wedged cached connection | **Fixed** 2026-08-10 — `invalidateMcpConnection` + lazy reconnect on next call |
| M-21 | `exec.run` stdout/stderr reader threads can deadlock the parent | **Fixed** 2026-08-10 — `forkFinally` readers always `putMVar`; main loop `try`s `hGetSome` |

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
| L-20 | `Runtime/Ignore.hs`                                          | **Fixed** (2026-08): ignore rules run first; hidden-segment default only when no rule matches (`!.env` un-ignores `.env`). |
| L-21 | `Runtime/Ignore.hs:168-181`                                  | `globMatch` naive backtracking (`any (go ps) (tails xs)`) — exponential on many-`*` rules vs long paths.                                                                               |
| L-22 | `Workspace.hs` `matchPat`                                    | **Fixed** (2026-08): `fs.find` / `fs.grep` extension globs compare ASCII case-insensitively.                                                                                          |
| L-23 | `Obs/Stream.hs:86-110`                                       | `appendText` read-modify-write not atomic; concurrent `onChunk` calls could drop text (single-threaded in practice).                                                                   |
| L-24 | `Workspace.hs` write/copy/remove                             | **Fixed** with H-1a: `O_NOFOLLOW` writes / `rename` copies close the leaf TOCTOU; `removePath` unlinks leaf symlinks.                                                                  |
| L-25 | `Parse/Section.hs:55-58,66-70`                               | `headings !! j` comprehension + fence rescan are O(n²) on large prose modules.                                                                                                         |
| L-26 | `Eval.hs` agent tool promote (`confirmOf` / `choiceOf` / `askOf`) | **Fixed** (2026-08): fail closed with `InternalErr` on machine shape mismatch instead of synthesizing an empty request. |
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

## Open items summary

**Fix when they bite:**

1. **M-16** — multi-process run-store locking (when parallel lab processes share a run dir).
2. **M-3** — skill-body prompt trust (when third-party skills matter).
3. Remaining **Lows** opportunistically (L-4, L-9–10, L-12, L-21, L-23, L-25, L-27 — fsync, CLI, glob ReDoS, stream append, section parse, mega-modules).

See [STATUS.md](STATUS.md) and [TASKS.md](TASKS.md).

---

## Method appendix

- **Pass 1 (map + sweep):** repo layout, `docs/STATUS.md`/`TASKS.md`/`architecture.md`; grep sweeps for `error`/`undefined`/`fromJust`, partial list functions, `unsafe*`/`trace`/`TODO`.
- **Pass 2 (deep reads):** six parallel read-only scouts over disjoint slices — runtime core, host boundary, LLM+agent, CLI/driver, parser/AST, checker/eval — each returning `path:line`-cited findings with severity.
- **Pass 3 (verification):** every High claim re-read directly; the one conflicting scout claim (Int div-by-zero) resolved against source (guarded); `cabal build` up to date; `.env` untracked (gitignored).
- **Pass 4 (2026-08-10):** architecture-mapped review of MCP stdio client, `Runtime/Mcp` registry, `Exec`/`ProcGroup`, store atomic rename, agent human-gate promotion. Executed MCP timeout→reuse probe (r2 timeout, r3 ok after wait). Spec §3 allowlist gap filed as H-8 (fixed same day). Coverage extended to post-audit MCP modules; prior open status reconfirmed for M-3 / M-16. M-18 was fixed in the subsequent implementation pass.
- **Coverage:** all `src/Hwfl/**` modules in initial pass; 2026-08-10 focused on MCP / Exec / Store / Eval human-gate paths. `app/Main.hs`, `hwfl.cabal`, dogfood `project.json` included.
