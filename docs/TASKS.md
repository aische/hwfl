# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P1)

- [ ] Skills phase D (optional) — `examples/skills/` writer; no hidden
      `skill.extract` host

## Next (P1–P2)

*(empty — promote from Later as needed)*

## Later (P2–P3)

- [ ] Semantic-check research phases (S4, S6) — see
      [semantic-check-plan.md](semantic-check-plan.md); S1–S3 + S5 shipped
- [ ] Run-store interface over `.hwfl/runs`, then optional DB-backed store
- [ ] Servant HTTP API on the same run/check APIs as the CLI
- [ ] MCP client (tool provider behind existing `tool(f)` / host-op story)

## Low priority

- [ ] Concurrent host transitions in `par` — overlap blocking IO (LLM,
      `fs.read`, `exec.run`) across branches via async at host boundaries;
      coordinator owns spans/snapshots; serial under `--step`. See
      [spec/06-runtime.md](spec/06-runtime.md) §10. M5 shipped the
      cooperative pool only.
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.) — interface
      shipped; second adapter is swap proof only
- [ ] In-language `lib/` modules (`list` / `string` / …) per [stdlib.md](stdlib.md)
- [ ] Deferred host/meta: `llm.chat_messages`, `meta.invoke`,
      `meta.list_runs`, `meta.read_spans`, `meta.read_snapshot`
- [ ] `fs.move` / `copy` / `mkdir` (P0 shipped list/edit/grep;
      `fs.write` creates parent dirs; `fs.read_slice` / `fs.remove` shipped)
- [ ] `hwfl init` / shell completions

## Future / nice-to-have (coding-agent capability)

Toward a Cursor-class **headless** agent. Prefer MCP / workflow modules over
growing the host-op set. MCP, `meta.invoke`, and concurrent `par` host IO are
listed above — not repeated here.

### Tier A — credible autonomous coding agent (backend)

- [x] `fs.patch` (structured multi-hunk edit) — unique matches, atomic;
      agent-tool eligible; coding-agent prefers over replace-all `fs.edit`
- [ ] Git host ops (read-heavy first): status / diff / log with sandbox
      policy; avoid brittle shell parsing
- [ ] Persistent terminal sessions (`term.*` or MCP terminal) — long test
      runs, dev servers, output tail (vs one-shot `exec.run`)
- [ ] Context pre-pass workflow module — rank / inject workspace files
      under a token budget before the agent loop

### Tier B — Cursor-class context

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep) for
      “find the right file” without many grep rounds
- [ ] LSP bridge host op — go-to-definition, references, diagnostics
- [ ] Project rules / hooks as always-loaded instruction skills (`.cursor/rules`
      equivalent; no hidden injection into every agent)
- [ ] Automatic context assembly — @file / open buffers / recent edits /
      failing tests → prompt prefix
- [ ] Multi-model routing — fast model for plan/grep; strong model for edits

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, background-agent notifications, browser /
multimodal — separate product; hwfl stays the orchestration kernel.

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07-15/16/17 completions (including P0 host gaps, coding-agent,
tool-call spans + `--debug`, lifecycle tutorial, skills A–C, try/catch runtime,
`--json` CLI errors, streaming LLM spans, semantic-check deepen / A+B / S2 /
S1 / S5 / S3).
