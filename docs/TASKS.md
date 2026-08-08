# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now (P0) — security / crash / trust

Order matters; do not skip ahead of H-6.

- [x] **H-1** — Retracted, not reproducible (see report). **H-1a** fixed
      instead: check containment before creating each parent component.
      Touches L-24.
- [x] **H-7** — Run-id validated as a single path component; start is
      create-only (reuse rejected)
- [x] **H-2** — Sync-exception barriers at run loop, host ops and provider;
      crash persists a failed machine
- [x] **H-6** — Checker/runtime calls align: `f()` only calls `Unit` domains;
      single record parameters pack positional or named fields
- [x] **H-3** — `jsonToValue` via `Scientific`; exact integers preserved and
      overflowing fractional `Double`s rejected
- [x] **H-4** — Reject non-finite floats at literal/arithmetic construction
      and JSON/render boundaries
- [x] **H-5** + **L-19** — Bounded `nextPow2`; validate source/snapshot
      `max_rounds`; reject non-positive and overflowing extensions

## Next (P1) — correctness / adjacent security

- [x] **M-1** — `llm.object` validates provider JSON against schema before
      converting it to a runtime value
- [x] **M-13** — Persist failed machine before finalizing the outcome; snapshot
      and meta both report failed, and resume cannot replay the failed step
- [x] **M-2** + **M-11(b)** — Redaction hardening; re-wrap `TSecret` model
      fields as `VSecret`
- [x] **M-7** — Contained, locale-safe module / project / catalog reads →
      diagnostics (no raw IOException in `--json`)

## Then (P2) — remaining Medium + author footguns

- [x] **M-8** — Resource limits: YAML alias bomb, parse depth, digit `read`,
      pure-eval / machine step budget, type-alias memoization
- [x] **M-6** — `exec.run`: stream/truncate before full buffer; process-group
      kill; validate timeout / max_output numerics
- [x] **M-10** — Effect residuals through let-aliases of top-level funs
- [x] **M-12** — Par: treat `PauseAwaitingAgent` / crash-recovery as not
      runnable
- [x] **M-9** — Diagnose YAML duplicate frontmatter keys
- [x] **M-15** — Surface pricing/catalog decode failure (do not silent-zero)
- [ ] **M-4** — `requestToTurns`: preserve all `RoleSystem` messages
- [ ] **M-11(a)** — Optional schema fields / `null` → option representation
- [ ] **M-3** — Skill-body prompt trust boundary (when third-party skills)
- [ ] **M-17** — Structured tool/provider errors vs string-sniff span status
- [ ] **M-18** — Project-hash / resume UX (only if prose edits brick resume
      too often)
- [ ] **L-5, L-6, L-14, L-16** — Parser/eval footguns: `a/b` QName, sequential
      let sugar, eager `&&`/`||`, duplicate record fields

## Later (P2–P3) — remaining Lows + deferred product

### Remaining Low (hygiene; fix opportunistically)

- [ ] **L-1–L-4, L-7–L-13, L-15, L-17–L-18, L-20–L-23, L-25** — spans, snapshot
      parse, fsync, slugs, CLI, variants, ignore/glob, etc. See report.

### Agent substrate (after bug pass)

Prefer MCP / workflow modules over growing the host-op set.

- [ ] MCP client (tool provider behind `tool(f)` / host-op story)
- [ ] Git (read-heavy host ops or MCP) — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot
      `exec.run`
- [ ] Opt-in `exec.runtime` = `host` \| `docker` behind `exec.run`
      (spec [05-host-ops.md](spec/05-host-ops.md) §3.1)

### Coding-agent / observability / research

- [ ] Workflow-driven skills coding-agent variant (separate example project)
- [ ] Opt-in LangSmith-style LLM transcripts
      ([07-observability.md](spec/07-observability.md) §10)
- [ ] Semantic-check S4 / S6; skills phase D; lab fitness `cost_micros`
- [ ] Omit / `latest` run-id for approve / choose / reply / show
- [ ] Concurrent host transitions in `par`
- [ ] Multi-process run-store locking (**M-16** — only when parallel lab
      processes share a run dir)

## Low priority

- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] In-language `lib/` modules per [stdlib.md](stdlib.md)
- [ ] `hwfl init` / shell completions
- [ ] Typed validation of example values vs `TypeExpr`; CLI `--example`

## Future / nice-to-have (coding-agent Tier B)

Delay until a measured coding-agent gap.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, browser / multimodal — control-plane or
other product; hwfl stays the orchestration kernel. Control plane /
Postgres live in **hwfl-server**, not here. See [idea.md](idea.md).

## Done

- **M-12** — Par cooperative freeze for agent budget exhaustion: not-runnable
  in `pickRunnable`, absorb/drain like human gates, `extend` bumps the branch
  `agMaxRounds`; crash-recovery branches stay parked (2026-08)
- **M-9** — Frontmatter YAML event walk rejects duplicate mapping keys
  (top-level and nested) before aeson last-wins decode (2026-08)
- **M-10** — `ELet` propagates callee residuals (and alias types) so
  `let g = f in g()` cannot under-report `f`'s effects past the module ceiling
  (2026-08)
- **M-6** — `exec.run` caps stdout/stderr while reading; timeout SIGTERM/SIGKILL
  the process group and returns partial capture; `timeout_ms` /
  `max_output_bytes` validated at project load and run (2026-08)
- **M-8** — Resource ceilings for untrusted input: frontmatter YAML rejects
  aliases and caps nesting/nodes; parsers bound nesting depth; digit literals
  parse linearly with a length cap; pure eval and CEK frames are fuel/depth
  bounded; type-alias resolve is memoized (2026-08)
- **M-7** — Module files decode from explicit UTF-8 bytes and turn read /
  decode failures into diagnostics; project discovery and pricing-catalog reads
  contain I/O errors. Existing malformed catalogs are config errors rather than
  silently zero-priced (2026-08)
- **M-15** — Superseded by M-7's catalog-read hardening: malformed existing
  catalogs now return a surfaced configuration error (2026-08)
- **M-2 + M-11(b)** — Reflected secret schema nodes retain an internal marker;
  `llm.object` and agent submit decoding restore `VSecret`, while provider
  requests strip the marker. Events and stderr redact sensitive-key,
  embedded-JSON, and common credential text (2026-08)
- **M-14** — `text.split_sentences` retains a non-blank unterminated final
  sentence after completed sentences; corpus tests cover final fragments and
  whitespace-only input (2026-08)
- **M-5** — Shared `fs.find` / `fs.grep` traversal refuses directory-symlink
  descent, verifies canonical directory containment, and tracks visited
  canonical directories to prevent cycles (2026-08)
- **M-19** — Record-domain host calls normalize packed records; `fs.move` /
  `exec.run` accept checked positionals; lone records unpack to multi-parameter
  functions; runtime parameters resolve aliases; bare singleton parameters are
  Unit thunks (2026-08)
- **M-1** — `llm.object` validates provider responses with
  `validateAgainstSchema` before `jsonToValue`; malformed or mistyped output
  becomes a normal `HostErr` and cannot violate the checked result type
  (2026-08)
- **M-13** — Ordinary evaluator failures persist the failed root machine before
      outcome finalization; `snapshot.json` and `meta.json` agree on failure,
      and resume returns the terminal failure without replaying it (2026-08)
- **H-5** + **L-19** — Bounded agent-budget suggestion; source and snapshot
  `max_rounds` validation; checked extension arithmetic (2026-08)
- **H-3** — JSON `Scientific` decode keeps all integral values as arbitrary-
  precision `VInt`; non-integral values that cannot be represented by a finite
  `Double` return conversion errors through LLM, agent-tool, and meta-read
  paths (2026-08)
- **H-6** — Empty application rejects non-`Unit` domains; `bindParams` supplies
  omitted `Unit`, and packs positional/named record fields for a single record
  parameter. `fs.write` accepts the two checked positional arguments (2026-08)
- **H-2** — `Hwfl.Exception.trySync` (sync only; async / `ExitCode` re-thrown)
  under `runUntilPause`, `runHostOp` and a new `safeLlmChat`. A crash mid-step
  closes the spans it opened, persists `MsFailed`, and surfaces as the new
  non-catchable `InternalErr`; the CLI has a last-resort envelope (2026-08)
- **H-7** — `validateRunId` (single path component) in the store; `createRun`
  is the only start path and rejects reuse; `openRunStore` /
  `tryOpenRunStore` removed; failure paths no longer create run dirs (2026-08)
- **H-1a** / **L-24** — Check-before-create parent chains; `O_NOFOLLOW` writes
  and `rename` copies; `fs.remove` unlinks leaf symlinks; `"symlink"` stat
  kind. H-1 itself retracted as not reproducible (2026-08)

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07 completions (P0, coding-agent, skills A–C, semantic-check
A+B / S1–S3 / S5, `fs.patch`, lab spine, E11, coding-agent chat, compare
mutate / next-gen, evolve-agent E23, `obs.log` non-snapshotting,
soft-land `max_rounds`, turing-machine exemplar + zero-arg funs,
nested snapshot outer-only persist (#1), `meta.invoke` sandbox (#2),
crash-safe store + run IDs (#3), checker holes for match/confirm/choice
(#4), submit schema validation + tool-name uniquify (#5)).
