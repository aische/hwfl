# hwfl Bug Report

- **Date:** 2026-08-05
- **Scope:** `src/Hwfl/**` (17,863 LOC across ~50 modules), `app/Main.hs`, `hwfl.cabal`, `model-catalog.json`
- **Method:** six parallel read-only reviews over disjoint module slices (runtime core, host boundary, LLM/agent, CLI/driver, parser/AST, checker/eval kernel), plus manual first-hand verification of every High-severity claim against source. `cabal build` up to date (compiles clean). `.env` present but gitignored and untracked — no keys committed.
- **Status:** findings identified; **none fixed yet**. This report is the durable source of truth for the findings; fixes should be tracked here until resolved.
- **Repository:** `hwfl` — durable workflow runtime library. Markdown modules (L1) → typed ML kernel: checker + pure evaluator (L2) → CEK machine with snapshot/resume, FS sandbox, `exec.run` allowlist, `llm.*` provider, human gates (L3). Run state persists under `workspace/.hwfl/runs/<run-id>/{meta.json, snapshot.json, spans.jsonl, events.jsonl, transitions.jsonl}`.

## Severity legend

| Level    | Meaning                                                    |
| -------- | ---------------------------------------------------------- |
| **High** | Crash, security breach, or data loss on plausible input    |
| **Med**  | Bug on edge input, robustness gap, or latent security hole |
| **Low**  | Latent risk, hygiene, or design wart                       |

Each finding carries a **Verification** tag:

- `[Verified]` — cited code read directly during this analysis.
- `[Reported]` — identified by a parallel review with quoted evidence; spot-corroborated.

---

## High

### H-1 — Sandbox escape: `fs.write` / `fs.copy` follow symlinks out of the workspace

- **Location:** `src/Hwfl/Runtime/Workspace.hs:171-177` (`writeTextFile`), `:424-425` (`copyOneFile`)
- **Verification:** `[Verified]`

`writeTextFile` validates the _parent_ directory by canonicalization, then checks the leaf only via `canonicalizePath target`:

```haskell
leafCheck <- try (canonicalizePath target) :: IO (Either IOException FilePath)
case leafCheck of
  Right leafCanon | not (isPathUnderRoot (workspaceRoot ws) leafCanon) ->
      pure (Left (SandboxErr "path escapes the workspace root"))
  _ -> do
    result <- try (BS.writeFile target (encodeUtf8 content)) ...
```

`canonicalizePath` **throws** on a dangling symlink (POSIX `realpath` ENOENT), so the `_ ->` fallback runs `BS.writeFile target` — which follows the link. A workflow (or repo content) that creates `link -> /tmp/x` and then `fs.write("link", …)` writes **outside the workspace**. `copyOneFile` is worse: it canonicalizes only the parent and calls `copyFile srcAbs target` with **no leaf check at all**; `copyPath`'s pre-check uses `doesPathExist` (follows symlinks), so even `overwrite=True` never removes a dangling link first.

- **Impact:** Arbitrary file write/copy outside the sandbox — the core security boundary of the runtime. Contents are limited to what the workflow can produce, but location and overwrite are attacker/author controlled.
- **Fix:** Leaf-level `lstat`-based symlink rejection or `O_NOFOLLOW` open for write/copy targets. Shared root cause: "canonicalize failed ⇒ treat as new path".

### H-2 — No exception containment in the run loop; any IO/pure exception kills the process

- **Location:** `src/Hwfl/Runtime/Eval.hs:400` (`runHostOp`), `:623` (`llmChat`); `src/Hwfl/Runtime/Host.hs:984,1009,1029`; `app/Main.hs` (no top-level handler; only a stdin-EOF `catch` at `:440`)
- **Verification:** `[Verified]` — grep confirms zero `try`/`catch`/`bracket`/`finally` in `Eval.hs` and `Run.hs`.

The run loop has **no exception barrier**. `result <- runHostOp host op args` and `result <- ctx.rcHost.heProvider.llmChat req` run unguarded; only `Llm/Simple.hs:61` wraps `loadModelOrThrow`. `Main.hs` has no `SomeException` handler, so the CLI dies with a raw GHC exception — no `--json` envelope, no `OutcomeFailed`.

- **Impact:** Any provider throw, disk-full during snapshot persist (`Store.hs:337-355`), or pure exception (H-3, H-4) crashes the process. `snapshot.json` holds the **pre-exception machine**; resume re-executes from it, **duplicating already-applied side effects** (double `exec.run`, double LLM spend). Last host span stays open.
- **Fix:** A `SomeException` barrier at the run-loop boundary converting exceptions to `RuntimeError`/`OutcomeFailed`; `try` around `llmChat`.

### H-3 — `jsonToValue` Double round-trip: silent integer corruption ≥ 2⁵³ and crash on huge magnitudes

- **Location:** `src/Hwfl/Json/Encode.hs:29-32`; reachable from `Host.hs:1045` (`llm.object`), `Agent.hs:372-374` (submit), `Agent.hs:676` (tool args), `Host.hs:704,800` (`meta.read_snapshot`/`read_spans`)
- **Verification:** `[Verified]`

```haskell
Aeson.Number n ->
  let d = realToFrac n :: Double
      i = round d :: Integer
   in if fromIntegral i == d then VInt i else VFloat d
```

Every JSON number funnels through `Double`. An integer ≥ 2⁵³ (`9007199254740993`) rounds to `9007199254740992` — **silent corruption**, even though `VInt` is arbitrary-precision `Integer` (`fromIntegral i == d` cannot detect it). A magnitude ≥ ~1.8e308 (model emits `1e999`) makes `d` infinite and `round Infinity` throws an arithmetic exception — which, per H-2, escapes as a crash.

- **Impact:** Untrusted LLM output (tool arguments, submit payloads, `llm.object` results, snapshot/span reads) either corrupts integers silently or crashes the process.
- **Fix:** Decode `Scientific` coefficient/exponent directly to `Integer`/`Double` without the Double detour; reject or trap non-finite magnitudes.

### H-4 — Non-finite floats from ordinary language code crash persist/encode

- **Location:** `src/Hwfl/Json/Encode.hs:43` (`VFloat d -> Aeson.Number (realToFrac d)`), `src/Hwfl/Runtime/Snapshot.hs:683` (`"v" .= d`), `src/Hwfl/Eval/Value.hs:225-229` (`renderFloat`); overflow source `src/Hwfl/Eval/Prelude.hs:169-170` (`num2` float ops)
- **Verification:** `[Verified]` (mechanism)

`1e308 * 10.0` produces `VFloat Infinity` — no NaN/Inf guard anywhere in the arithmetic builtins. The value then reaches Aeson via `realToFrac d :: Scientific` (or `renderFloat`'s `round d :: Integer`), both of which **throw on NaN/Infinity**. Any snapshot persist or `json.encode` of the value crashes the run (escapes per H-2).

- **Impact:** Float overflow → process crash with stale snapshot → duplicate side effects on resume.
- **Fix:** Guard `isNaN`/`isInfinite` at arithmetic results and/or at encode/render, converting to a `Trap`/`RuntimeError`.

### H-5 — `nextPow2` non-termination (DoS) on large budget values

- **Location:** `src/Hwfl/Runtime/Eval.hs:1610-1613` (`suggestExtraRounds`/`nextPow2`); reachable via snapshot `max_rounds`/`round` (`Snapshot.hs:341-347`) and `extendAgentMachine` wrap (`Eval.hs:1616-1624`)
- **Verification:** `[Verified]`

```haskell
nextPow2 n = head [p | p <- map (2 ^) [(0 :: Int) ..], p >= n]
```

For `n > 2^62`, `2^63` overflows `Int` to `minBound` (negative); no element ever satisfies `p >= n`, so `head` scans the infinite list **forever**. `suggestExtraRounds` is called whenever an agent exhausts its budget. A crafted snapshot with `"max_rounds": 9223372036854775807` (or `--rounds` extension that wraps `agMaxRounds + extra` into that range) **hangs the single-threaded run loop**.

- **Impact:** DoS via crafted run state or a large config value.
- **Fix:** `ceiling (logBase 2 …)` or a bounded search with overflow check.

### H-6 — Checker/runtime divergence: accepted programs trap at runtime

- **Location:** `src/Hwfl/Check/Infer.hs:389-395` (`f()` on non-Unit), `:398-404` (positional args zip-checked against record _fields_); runtime side `src/Hwfl/Eval/Pure.hs:113-133` (`bindParams`); host-op record stubs `src/Hwfl/Check/Prelude.hs:141-149`
- **Verification:** `[Verified]`

1. `go ty []` — for `f() : Int -> Int`, when the domain isn't `Unit` it returns `Right ty` (the **function type itself**) instead of an error. `f()` typechecks; runtime applies `f` to zero args → `bindParams` arity `Trap`.
2. `applyPositional` — when `length args == length fields` it zips positional args against record fields: `f {a=1} {b=2}` for `fun (a: Int, b: Int)` checks each record against a _field_ type and accepts. Runtime `bindParams` binds `a := {a=1}` (a record where `Int` was promised) → downstream arithmetic traps. Same class: `fs.write("a.txt", "hi")` typechecks against the record stub `{path, text}`; the driver receives two positionals.

- **Impact:** The type checker promises `Int`/valid calls for programs that crash at runtime — checker soundness hole on ordinary author input.
- **Fix:** Align `applyPositional`/`applyNamed` with `bindParams`, or reject the divergent shapes at check time.

### H-7 — Unsanitized run-id is joined into a filesystem path (library API)

- **Location:** `src/Hwfl/Runtime/Run.hs:373` (`maybe newRunId pure opts.roRunId`), `src/Hwfl/Runtime/Store.hs:192-194` (`openRunStore` → `T.unpack runId </>` + `createDirectoryIfMissing True`), `:183-186` (`openRunDir`)
- **Verification:** `[Verified]`

`runTarget`/`resumeRun`/`approveRun`/… take the run-id verbatim and join it into `workspace/.hwfl/runs/<run-id>`, creating directories with `createDirectoryIfMissing True`. A run-id of `../../x` gives **arbitrary directory creation plus `meta.json`/`snapshot.json` read/write outside the workspace**. The CLI only exposes run-id positionally (operator-trusted), but the library API — the control-plane surface per `docs/architecture.md` — accepts caller-supplied ids.

Related: **explicit run-id reuse merges runs** (`Run.hs:373-375`, `Store.hs:284-289`) — no existence check; old `snapshot.json`/`spans.jsonl` survive while `meta.json` is atomically clobbered and the seq resets to 0, so a crash before first persist leaves new meta + previous run's machine (same project hash) → duplicated execution and mixed spans.

- **Fix:** Validate run-id as a single path component (no `/`, `.`, `..`); reject reuse of an existing run id unless explicitly intended.

---

## Medium

### M-1 — `llm.object` never validates model JSON against the schema

- **Location:** `src/Hwfl/Runtime/Host.hs:1031-1045`; `src/Hwfl/Json/Validate.hs` wired only to agent submit (`Agent.hs:372-374`)
- **Verification:** `[Reported]`, corroborated by code read at `Host.hs:1042-1045`

The schema is passed to the provider only as a `chatResponseFormat` hint; `decodeJsonObject` → `jsonToValue` accepts anything. A model returning `{"score": "high"}` for `schema({score: Int})` flows to user code as `VString` where the checker promised `Int` — checker soundness voided (H-6 family).

### M-2 — Redaction gaps: embedded, short, and oddly-keyed secrets leak to events and stderr

- **Location:** `src/Hwfl/Obs/Redact.hs:53-86`; `src/Hwfl/Obs/Stream.hs:143-147` (unredacted `debugLog` of LLM deltas); `src/Hwfl/Obs/Observer.hs:64` (raw stderr); `Run.hs:626` (host-op logs unredacted to stderr)
- **Verification:** `[Reported]`

`Aeson.String` values are redacted only when the _whole string_ looks like a secret; a tool-call arg or `obs.log` field containing `{"api_key":"sk-...","password":"x"}` passes through. Key detection misses `private_key`, `passphrase`, `pwd`, `pem` (not in the list, don't contain the infix substrings). Token heuristics miss 40+ char lowercase hex, JWTs (contain `.`), and short tokens. `--debug` writes raw delta text and host-op lines to stderr unredacted; `snapshot.json` itself is `VSecret`-safe (`Snapshot.hs:715-716`), and span attrs are redacted at write time (`Trace.hs:89-90`), but embedded secrets in plain `VString` args/stdout are not.

### M-3 — Skill bodies injected verbatim into the system prompt (prompt injection with agent powers)

- **Location:** `src/Hwfl/Runtime/Skills.hs` (`instructionInjectionText`)
- **Verification:** `[Reported]`

Skill markdown bodies are concatenated into the system prompt each round, and skills are loaded **at the model's own request**. Content is project-authored today, but a third-party skill (e.g. cloned from a repo) can instruct the model with tool-calling authority. No trust boundary or instruction-delimiting.

### M-4 — `requestToTurns` drops all but the first `RoleSystem` message

- **Location:** `src/Hwfl/Llm/Simple.hs`
- **Verification:** `[Reported]`

### M-5 — `fs.find`/`fs.grep` descend directory symlinks without canonicalization or cycle checks

- **Location:** `src/Hwfl/Runtime/Workspace.hs:209-226` (`walk`/`one`), `:699-713` (`walkAll`)
- **Verification:** `[Reported]`

`doesDirectoryExist` follows symlinks, then `walk` recurses. A workspace symlink `up -> ..` or `abs -> /` makes `fs.find` walk the parent or entire filesystem and **return out-of-workspace filenames** (extension-matched); a self-referential link recurses until ENAMETOOLONG, aborting the op. File _content_ stays guarded (`grepOne` re-validates via `resolveContainedPath`).

### M-6 — `exec.run` resource handling: output fully buffered, timeout kills only the direct child

- **Location:** `src/Hwfl/Runtime/Exec.hs:93,102-118,144-147`
- **Verification:** `[Reported]`, code read at `Exec.hs:36-153`

`truncateStream` runs **after** typed-process has accumulated the child's entire output in memory — a child printing gigabytes for the full 120 s timeout OOMs the host despite `execMaxOutputBytes`. `System.Timeout.timeout` interrupts the thread and `withProcessTerm` terminates only the direct pid, not the process group: grandchildren (`sh -c 'server &'`, `make` children) survive, keep the pipes open, and their output is discarded on timeout (empty stdout/stderr in the timed-out outcome). Policy numerics unvalidated: negative `timeout_ms` → 1 µs timeout; negative `max_output_bytes` → empty output.

### M-7 — `loadModule` uses uncaught, locale-dependent `TIO.readFile`

- **Location:** `src/Hwfl/Parse/Load.hs:29`
- **Verification:** `[Reported]` (text-2.0.2 semantics verified)

`TIO.readFile` is locale-dependent and throws on invalid byte sequences; a missing file, directory, binary, or invalid-UTF-8 module yields a **raw uncaught IOException** instead of `Left [Diagnostic]` — no `--json` envelope even in `--json` mode. Same class: `BS.readFile project.json` (`Project.hs:147-148`), `LBS.readFile` catalog, `listDirectory`.

### M-8 — Resource exhaustion on untrusted input (parse/eval/check)

- **Locations:** YAML alias bomb `src/Hwfl/Parse/Frontmatter.hs:95`; parser depth `src/Hwfl/Parse/Expr.hs:282`, `src/Hwfl/Parse/Type.hs:51`; unbounded `read` on digit runs `src/Hwfl/Parse/Pat.hs:71,79`, `Parse/Expr.hs:352`; pure evaluator no recursion budget `src/Hwfl/Eval/Pure.hs`; type-alias expansion unmemoized `src/Hwfl/Check/Infer.hs:58`
- **Verification:** `[Reported]`

- YAML alias expansion is eager and unshared: a ~200-byte frontmatter with 20 levels of 4×-branching aliases expands to ~10¹² nodes → OOM on module load.
- Recursive-descent parsers (`expr ↔ primary ↔ (expr)`, `List<List<…>>`) have no depth limit → `StackOverflow` (an exception, not a diagnostic) on ~10-20 MB of nesting.
- `read (T.unpack ds)` for `Integer` is superlinear: a ~1 MB all-digit literal effectively hangs. `read` for `Double` silently yields `Infinity` (pretty-prints non-reparseable).
- Pure `eval` recurses in Haskell with no step budget: `fun f() -> f()` overflows the stack with an uncaught exception; the machine runtime has no max-frame bound either.
- `resolveTypeFrom` re-expands every alias occurrence: a shared DAG at depth ~50 expands ~2⁵⁰ nodes → check-time DoS.

### M-9 — YAML duplicate keys silently last-wins

- **Location:** `src/Hwfl/Parse/Frontmatter.hs:93-100`
- **Verification:** `[Reported]`

`Data.Yaml.decodeEither'` builds a map-backed KeyMap; `name: a` then `name: b` (and duplicate `inputs:`/`outputs:` fields) silently override — wrong module identity/typing accepted with no diagnostic.

### M-10 — Effects of a top-level fun called through a let-alias are lost

- **Location:** `src/Hwfl/Check/Effects.hs:82-85,123-124`
- **Verification:** `[Reported]`

`calleeResidual (EVar n)` looks up only top-level names; `let g = f in g()` yields `{}` for `f`'s `{Write}`. Module `meEffects` under-reports → an importing module can pass a purity ceiling while executing host writes through the alias.

### M-11 — `TOption` fields forced `required`; `TSecret` flattened to inner schema

- **Location:** `src/Hwfl/Check/Schema.hs:84-88`
- **Verification:** `[Reported]`

(a) `required` lists every field, so an absent optional field fails validation while runtime `jsonToValue` maps `null` → `VUnit` — no `Nothing` representation, downstream matches on options trap. (b) Secret fields emit the _inner_ schema and nothing re-wraps the model's response in `VSecret`, so secrets round-trip as plain `VString`, **bypassing redaction** (M-2).

### M-12 — Par branch agent-budget exhaustion misclassified as "no progress"

- **Location:** `src/Hwfl/Runtime/Eval.hs:1900-1903,1865`
- **Verification:** `[Reported]`

`pickRunnable`'s catch-all `_ -> True` treats `MsPaused (PauseAwaitingAgent _)` (and `PauseCrashRecovery`) as runnable; the picked branch's step makes no transition → "par branch made no progress" trap → `absorbFailed` → with `ParFail` the whole join fails. The awaiting-extend pause is unreachable inside `par`.

### M-13 — Failure states are not durable; meta/snapshot status divergence

- **Location:** `src/Hwfl/Runtime/Eval.hs:247`, `src/Hwfl/Runtime/Run.hs:497-516`
- **Verification:** `[Reported]`

`runUntilPause`'s `Left err -> pure m {mStatus = MsFailed, …}` never persists the failed machine; `meta.json` flips to `"failed"` while `snapshot.json` keeps the pre-failure machine. Resume after crash re-executes from before the failing step (only `doHostRun`/`failAgent`/`finishJoin` persist their own failure paths).

### M-14 — `splitSentences` drops the final sentence

- **Location:** `src/Hwfl/Text/Corpus.hs:101-106`
- **Verification:** `[Reported]`

`consume [] acc cur` returns `reverse acc`, discarding the trailing `cur`: `text.split_sentences("One. Two")` → `["One."]` — data loss in a user-facing builtin.

### M-15 — Pricing/catalog decode failure silently disables all cost accounting

- **Location:** `src/Hwfl/Llm/Pricing.hs:66-70`
- **Verification:** `[Reported]`

`Aeson.eitherDecode` failure → `emptyModelPricing` — all costs report zero with no diagnostic. Whole-file catalog corruption is invisible.

### M-16 — Concurrent approve/choose/reply on one run: no lock, double execution, torn snapshot

- **Location:** `src/Hwfl/Runtime/Store.hs` (shared `snapshot.json.tmp` + rename), `src/Hwfl/Runtime/Run.hs` (`approveRun`/`chooseRun`/`replyRun` run the full continuation)
- **Verification:** `[Reported]`

Two processes approving the same paused run both run the full continuation (double LLM spend, double `exec.run` side effects) and both write `snapshot.json.tmp` then rename — interleaved writes can tear `snapshot.json` and brick resume. Multi-process locking is explicitly deferred in `docs/TASKS.md`; this notes the concrete failure mode when it bites (parallel lab processes).

### M-17 — Provider errors: finish-reason ignored; `--debug` string-sniffing for span status

- **Location:** `src/Hwfl/Runtime/Eval.hs` (`completeToolCall`), `:1096-1100`
- **Verification:** `[Reported]`

Span status is inferred by prefix-matching tool result text (`"tool error"`, `"tool open failed"`, `"submit decode error"`) rather than structured errors; finish reason from the provider is ignored.

### M-18 — Project hash includes full prose bodies → resume falsely reports "stale project"

- **Location:** `src/Hwfl/Project.hs` (`projectHashForModules`)
- **Verification:** `[Reported]`

Any whitespace/prose edit to a module changes the hash and blocks resume with `ConfigErr "stale project: hash mismatch"` — safe, but a comment edit bricks an otherwise valid resume.

---

## Low

| ID   | Location                                                     | Issue                                                                                                                                                                                  |
| ---- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ---------------------------------------------------------------------------------- |
| L-1  | `Eval.hs:626+1194, 675+1194`                                 | Double-close of the agent round span on provider error / submit-required path. `closeSpan` is not idempotent (`Trace.hs:129-143`); duplicate close records, cost attrs charged twice.  |
| L-2  | `Run.hs:1183-1192`, `Trace.hs:141-143`                       | Span-stack staleness: mid-region failure leaves `FrRegion` open; `pop` is a no-op for non-head ids; resumed runs parent new spans under closed ids.                                    |
| L-3  | `Snapshot.hs:186-188,93`                                     | `parsePauseReason` ends in `<\|> pure PauseExplicit` — malformed pause payloads silently downgrade to explicit; `snapshot_format` never validated (future format bumps undetected).    |
| L-4  | `Store.hs:336-355,373-380`                                   | No fsync anywhere (tmp + rename only; spans/events plain append). Crash-safe, not power-loss-safe; power loss can lose the rename or persist a torn file → run unrecoverable.          |
| L-5  | `Parse/Expr.hs:303-308,84`                                   | `a / b` with two bare identifiers parses as QName (module ref), never division — silent when module `a/b` exists; `x / y` only divides when the left operand isn't a bare ident.       |
| L-6  | `Parse/Expr.hs:110-118`                                      | Sequential-let sugar's third branch is a bare `expr`: `let x = a b` silently parses as `let x = a in b` (juxtaposition otherwise a syntax error).                                      |
| L-7  | `Parse/Section.hs:16-27`                                     | `computeSlug` strips all non-ASCII: `"Über"`→`"ber"`, `"Café"`→`"caf"`; distinct headings and `a b`/`a-b` collapse; no duplicate-slug check — `@slug` refs can bind the wrong section. |
| L-8  | `Check/Project.hs:202-212`                                   | `findCycle` follows only the first dep, never backtracks, and can report a non-cyclic path (even a single node) as `PceImportCycle`. Cycle _detection_ (Left vs Right) is correct.     |
| L-9  | `Parse/Markdown.hs:87-100`                                   | Frontmatter requires `---` on line 1 and `T.strip` doesn't remove U+FEFF: BOM or leading blank hides frontmatter; BOM inside a fence is a lexer error.                                 |
| L-10 | `Frontmatter.hs:97-146`                                      | All frontmatter errors pinned at `Pos 1 1`; YAML's own line/col info discarded.                                                                                                        |
| L-11 | `Frontmatter.hs:90`                                          | `parseTags` silently drops non-string entries (`tags: [1, "a"]` keeps only `"a"`).                                                                                                     |
| L-12 | `Frontmatter.hs:34,186`                                      | `qnameFromText` unvalidated (`""`, `"a//b"`, `"/x"`, `".."` accepted); caught downstream with confusing messages. No traversal risk (index-only resolution).                           |
| L-13 | `Main.hs`                                                    | `reportUsage` misdetects `--json` when consumed as a flag value; `-`-prefixed paths rejected as flags; `exitCodeFor` substring-matches `"stale project"`.                              |
| L-14 | `Eval/Prelude.hs:99-100`                                     | `&&`/`                                                                                                                                                                                 |     | `eager, not short-circuiting:`false && (1/0 == 0)` traps. Divergence risk vs docs. |
| L-15 | `Json/Encode.hs:47-49`                                       | `VVariant t Nothing` encodes as JSON string, decodes back as `VString` — variant round-trip changes type.                                                                              |
| L-16 | `Check/Infer.hs` (ERecord), `Env.hs:117-126`, `Encode.hs:46` | Duplicate record fields accepted; projection takes first, `json.encode` dedups to last → `r.a == 1` but encoded `{"a":2}`; `typeEq` rejects such records.                              |
| L-17 | `Check/Prelude.hs:360`, `Infer.hs:736-745,770-773`           | Curried `obs.span("n")(thunk)` returns `Unit` while the 2-arg form returns the body type — inconsistent over-strict typing.                                                            |
| L-18 | `Check/Module.hs:91-99`                                      | Example input _values_ are untyped; `String` example where `Int` declared passes check.                                                                                                |
| L-19 | `Agent.hs:385-387`, `Snapshot.hs:341-347`                    | `max_rounds` `fromIntegral` wraps on huge values (feeds H-5); `agMaxRounds + extra` can overflow.                                                                                      |
| L-20 | `Runtime/Ignore.hs:69-105`                                   | `isIgnored` checks hidden segments before rules, so `!.env` can never un-ignore a hidden name — deviates from gitignore semantics.                                                     |
| L-21 | `Runtime/Ignore.hs:168-181`                                  | `globMatch` naive backtracking (`any (go ps) (tails xs)`) — exponential on many-`*` rules vs long paths.                                                                               |
| L-22 | `Workspace.hs:232-238`                                       | `matchPat` compares extensions case-sensitively; `**/*.MD` misses `foo.md` on macOS, finds it on Linux — host-FS-dependent behavior.                                                   |
| L-23 | `Obs/Stream.hs:86-110`                                       | `appendText` read-modify-write not atomic; concurrent `onChunk` calls could drop text (single-threaded in practice).                                                                   |
| L-24 | `Workspace.hs:171-177`                                       | TOCTOU on write: `canonicalizePath`→`writeFile` check/use window; no `O_NOFOLLOW`. Also `removePath` cannot delete a dangling symlink.                                                 |
| L-25 | `Parse/Section.hs:55-58,66-70`                               | `headings !! j` comprehension + fence rescan are O(n²) on large prose modules.                                                                                                         |

---

## Verified solid (do not re-report)

- **Read-path sandbox** — `resolvePath` (lexical `..`/absolute rejection) + `resolveContainedPath` (canonicalize + root-prefix) correctly block `..`, absolute, and symlink escapes for read/list/remove/stat/read_slice/edit/patch; null bytes surface as caught `IOException` → `HostErr`, never an escape.
- **`exec.run` policy** — bare-basename-only (no `/`), allowlist gates the binary, `setEnv` replaces the whole environment with only `exec.env` keys (no parent-env leakage), confirm default `True`, stdout/stderr fully captured (never leaks to terminal), `withProcessTerm` on timeout. Defaults are safe: `allow`/`env` default to `[]`.
- **Corrupt-snapshot handling** — all parser `fail` sites (`Snapshot.hs:571-574`, `:821`, `:829-832`, …) are contained by `parseEither`; corrupt `snapshot.json`/`meta.json` → clean `ConfigErr "missing meta.json or snapshot.json"`, never a crash or state corruption. Project-hash check refuses stale-project resume.
- **Division by zero** — `div2` (`Eval/Prelude.hs:173-177`) guards **both** `Int` and `Float` zero divisors with `Trap`. _One review claimed Int div-by-zero was unguarded; direct read shows it is guarded — corrected here to prevent re-reporting._ `/` routes `BDiv → div2`.
- **Alias cycle detection** — `resolveAliasDef`/`resolveTypeFrom` stack-seeded, self-/mutual-/deep cycles all produce `AliasCycle`; `DuplicateType`/`DuplicateFun` cover redecls.
- **Secrets in snapshots** — `VSecret` persists as `"[REDACTED]"` (`Snapshot.hs:715-716`); span attrs redacted at write time.
- **Run-id auto-generation** — wall-clock second + 64-bit hex nonce (`Run.hs:1237-1241`); collision-resistant; hazard is only explicit reuse (H-7).
- **Lexer/parser core** — `tripleString` safe (megaparsec `tokens` restores state), `attachSourcePos errorOffset` correct, unterminated strings/comments give clean EOF diagnostics, position seeding consistent; no reachable unguarded `head`/`fromJust`/`read` on CLI input; `last xs` sites guarded.
- **Torn-line tolerance** — spans/events/transitions readers use `mapMaybe decode`; torn trailing lines are skipped.

---

## Recommended fix order

1. **Exception barrier** at the run-loop boundary + `try` around `llmChat` (fixes H-2; converts H-3/H-4 from crashes into `RuntimeError`s).
2. **`jsonToValue` via `Scientific`** — coefficient/exponent to `Integer`/`Double`, trap non-finite (fixes H-3, half of H-4).
3. **Leaf-level `O_NOFOLLOW`/`lstat`** on write/copy targets (fixes H-1).
4. **Sanitize run-id** (single path component) + existence check before reuse (H-7).
5. **`nextPow2`** — `ceiling (logBase 2 …)` or bounded search (H-5).
6. **Align `applyPositional`/`applyNamed` with `bindParams`** or reject divergent shapes at check time (H-6, M-1).
7. Redaction hardening (M-2), then the resource-exhaustion cluster (M-8), then the rest.

---

## Method appendix

- **Pass 1 (map + sweep):** repo layout, `docs/STATUS.md`/`TASKS.md`/`architecture.md`; grep sweeps for `error`/`undefined`/`fromJust`, partial list functions, `unsafe*`/`trace`/`TODO`.
- **Pass 2 (deep reads):** six parallel read-only scouts over disjoint slices — runtime core, host boundary, LLM+agent, CLI/driver, parser/AST, checker/eval — each returning `path:line`-cited findings with severity.
- **Pass 3 (verification):** every High claim re-read directly; the one conflicting scout claim (Int div-by-zero) resolved against source (guarded); `cabal build` up to date; `.env` untracked (gitignored).
- **Coverage:** all 50 `src/Hwfl/**` modules read in full across the six slices; `app/Main.hs`, `hwfl.cabal`, `model-catalog.json` included. Test suite and examples excluded except for cross-checks.
