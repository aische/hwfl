# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P1) — runtime integrity (issues.md High #1–#5)

Source review 2026-07-21 (`issues.md`). Fix in this order; do not lean
harder on nested invoke / E11 until 1–3 land.

- [ ] **#1 Nested snapshot persist** — never write a bare `BranchMachine`
      as root `snapshot.json` (agent tools / `FrInvoke` / `par`); persist
      only the outer machine (or a dedicated nested-store encoding)
- [ ] **#2 `meta.invoke` sandbox** — resolve `project` / `workspace`
      through the same containment as `fs.*` (`resolvePath` /
      canonicalize); reject abs / `../` escape
- [ ] **#3 Crash-safe store + run IDs** — atomic snapshot writes
      (`write temp + rename`); collision-resistant `newRunId` (not
      second-granularity). Locking deferred until multi-process lab
- [ ] **#4 Checker holes** — reject empty `match`; check
      `confirm` / `choice` record shape; reject missing required fields
      instead of coercing to `""`
- [ ] **#5 Agent submit / tool identity** — real schema validation for
      `llm.agent_object` submit (beyond presence-only); uniquify
      sanitized tool names before advertising to the provider

## Next (P1) — lab loop + exemplars

- [ ] Credible coding-agent exemplar: tools that call same-project
      workflows (`FrInvoke` / E11), not only host ops

## Next (P1–P2) — agent substrate

Prefer MCP / workflow modules over growing the host-op set.

- [ ] MCP client (tool provider behind `tool(f)` / host-op story)
- [ ] Git (read-heavy host ops or MCP) — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot
      `exec.run`
- [ ] Context pre-pass workflow module — rank files under a token budget

## Later (P2–P3)

### Observability

- [ ] Opt-in LangSmith-style LLM transcripts — durable messages in/out
      keyed by `span_id` (`transcripts.jsonl` or `payloads/`); spans stay
      the thin index. CLI `--trace` / run option; redact + size caps.
      See [spec/07-observability.md](spec/07-observability.md) §10.

### Research / optional

- [ ] Semantic-check S4 / S6 — parked; see
      [semantic-check-plan.md](semantic-check-plan.md); optional fitness
      filter for lab candidates
- [ ] Optional: lab fitness sum `cost_micros` (spans already counted)
- [ ] Skills phase D (optional) — `examples/skills/` writer; no hidden
      `skill.extract` host
- [ ] Optional: omit / `latest` run-id for approve / choose / reply / show
      (resolve from workspace run store by status + recency)

### Parallelism

- [ ] Concurrent host transitions in `par` — overlap blocking IO across
      branches; **or** run lab candidates as external parallel processes.
      See [spec/06-runtime.md](spec/06-runtime.md) §10.
- [ ] Multi-process run-store locking (only if external parallel lab
      processes share a run dir)

## Low priority

- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] In-language `lib/` modules per [stdlib.md](stdlib.md)
- [ ] `hwfl init` / shell completions
- [ ] Typed validation of example values vs `TypeExpr`; CLI `--example`

## Future / nice-to-have (coding-agent Tier B)

Delay until a measured lab / coding-agent gap.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, browser / multimodal — control-plane or
other product; hwfl stays the orchestration kernel. Control plane /
Postgres live in **hwfl-server**, not here. See [idea.md](idea.md).

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07 completions (P0, coding-agent, skills A–C, semantic-check
A+B / S1–S3 / S5, `fs.patch`, lab spine, E11, coding-agent chat, compare
mutate / next-gen, evolve-agent E23, `obs.log` non-snapshotting,
soft-land `max_rounds`, turing-machine exemplar + zero-arg funs).
