# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now (P0) — security / crash / trust

Order matters; do not skip ahead of H-2.

- [x] **H-1** — Retracted, not reproducible (see report). **H-1a** fixed
      instead: check containment before creating each parent component.
      Touches L-24.
- [x] **H-7** — Run-id validated as a single path component; start is
      create-only (reuse rejected)
- [ ] **H-2** — `SomeException` barrier at run-loop + `try` around `llmChat`
- [ ] **H-6** — Align checker `applyPositional` / `applyNamed` with `bindParams`
- [ ] **H-3** — `jsonToValue` via `Scientific` (no Double detour); trap
      non-finite
- [ ] **H-4** — Guard NaN/Inf at float arith and/or encode/render
- [ ] **H-5** + **L-19** — Bounded `nextPow2`; fix `max_rounds` /
      `agMaxRounds + extra` wrap

## Next (P1) — correctness / adjacent security

- [ ] **M-1** — Validate `llm.object` JSON against schema (agent submit already
      does)
- [ ] **M-5** — `fs.find` / `fs.grep`: no directory-symlink descent; cycle /
      containment checks
- [ ] **M-13** — Persist failed machine; keep meta/snapshot status aligned
- [ ] **M-14** — `text.split_sentences` must keep the final sentence
- [ ] **M-2** + **M-11(b)** — Redaction hardening; re-wrap `TSecret` model
      fields as `VSecret`
- [ ] **M-7** — Contained, locale-safe module / project / catalog reads →
      diagnostics (no raw IOException in `--json`)

## Then (P2) — remaining Medium + author footguns

- [ ] **M-8** — Resource limits: YAML alias bomb, parse depth, digit `read`,
      pure-eval / machine step budget, type-alias memoization
- [ ] **M-6** — `exec.run`: stream/truncate before full buffer; process-group
      kill; validate timeout / max_output numerics
- [ ] **M-10** — Effect residuals through let-aliases of top-level funs
- [ ] **M-12** — Par: treat `PauseAwaitingAgent` / crash-recovery as not
      runnable
- [ ] **M-9** — Diagnose YAML duplicate frontmatter keys
- [ ] **M-15** — Surface pricing/catalog decode failure (do not silent-zero)
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
