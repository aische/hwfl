# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P1) — lab spine

- [x] Library driver façade — check / run / step / resume / approve / show
      as one API the CLI wraps (control plane will call the same)
- [x] Run-store interface over `.hwfl/runs` (list / read meta / spans /
      snapshot); FS backend first
- [x] `meta.invoke` — nested module/project run with inputs; return
      run_id + outcome (snapshot boundary)
- [x] `meta.list_runs` / `meta.read_spans`
- [x] Careful `meta.read_snapshot` (redact secrets)
- [x] Local compare / genetic prototype — `examples/compare` (materialize
      N projects + per-trial workspaces; score outcome + llm span count)

## Next (P1–P2)

- [ ] Observer hook for live span / pause events (CLI `--debug` today;
      WS/SSE maps onto this in the control-plane repo)

## Later (P2–P3)

- [ ] Optional DB-backed run-store backend (same interface; not required
      for local lab)
- [ ] MCP client (tool provider behind `tool(f)` / host-op story)
- [ ] Skills phase D (optional) — `examples/skills/` writer; no hidden
      `skill.extract` host
- [ ] Semantic-check research (S4, S6) — parked; see
      [semantic-check-plan.md](semantic-check-plan.md); optional fitness
      filter for lab candidates

## Out of this repo

- Remote control plane (Servant/HTTP, WebSocket/SSE approve gates,
  Postgres experiment metadata, multi-tenant auth, queue, chat UX) —
  **separate project** depending on the hwfl library. See [idea.md](idea.md).

## Low priority

- [ ] Concurrent host transitions in `par` — overlap blocking IO across
      branches; or run lab candidates as external parallel processes.
      See [spec/06-runtime.md](spec/06-runtime.md) §10.
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] In-language `lib/` modules per [stdlib.md](stdlib.md)
- [ ] `llm.chat_messages`; `fs.move` / `copy` / `mkdir`; `hwfl init` /
      shell completions

## Future / nice-to-have (coding-agent capability)

Headless agent benchmark for the lab. Prefer MCP / workflow modules over
host growth. Delay RAG / embeddings / LSP until a measured gap.

### Tier A — credible autonomous coding agent (backend)

- [x] `fs.patch` (structured multi-hunk edit)
- [ ] Git host ops (read-heavy) or MCP git — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot `exec.run`
- [ ] Context pre-pass workflow module — rank files under a token budget

### Tier B — Cursor-class context

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, browser / multimodal — control-plane or
other product; hwfl stays the orchestration kernel.

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07-15/16/17 completions (including P0, coding-agent, skills A–C,
semantic-check A+B / S1–S3 / S5, `fs.patch`, `--cost`).
