# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now

- [ ] **Name freeze or rename** — CLI, fence info-string, `hwfl/` stdlib
      qnames, `.hwfl/` run dir. Do this before a public tag.

## Language + interpreter (ongoing policy)

Prefer MCP clients and in-language modules (`hwfl/*` stdlib, project
`lib/`) over growing the host-op set. See
[architecture.md](architecture.md).

- [ ] **Host ops** — add new host categories only when the language cannot
      express the need; otherwise MCP or stdlib / `lib/`

## Next — examples and polish

- [ ] Git (read-heavy) via MCP (or host if MCP is inadequate)
- [ ] Persistent terminals via MCP vs one-shot `exec.run`
- [ ] Optional: real-story-writer `world_*` via `mcp.tools` (bind /
      filter commit)
- [ ] Opt-in LangSmith-style LLM transcripts
      ([07-observability.md](spec/07-observability.md) §10)
- [ ] Concurrent host transitions in `par`
- [ ] Workflow-driven skills coding-agent variant; semantic-check S4/S6;
      skills phase D; lab fitness `cost_micros`

## Deferred bugs (fix only if they bite)

- [ ] **M-3** — Skill-body prompt trust boundary (when third-party skills)
- [ ] **M-16** — Multi-process run-store locking (when parallel processes
      share a run dir)
- [ ] **Remaining Lows** — L-4, L-9–10, L-12, L-21, L-23, L-25, L-27
      (fsync, CLI, glob ReDoS, stream append atomicity, section parse
      O(n²), mega-modules)

## Low priority

- [ ] `consolidate = "llm"` — Context L2 LLM summarizer + lasting
      `context` seed/return (pins/summary/watermark); update host-op /
      [manual/library/llm.md](../manual/library/llm.md). Design notes:
      [log/2026-08.md](log/2026-08.md) (2026-08-08 — agent context layers /
      coding-agent-chat lasting context)
- [ ] Opt-in `exec.runtime` = `host` \| `docker` behind `exec.run`
      (spec [05-host-ops.md](spec/05-host-ops.md) §3.1)
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] Shell completions (with or after `hwfl init`)

## Future / nice-to-have

Delay until a concrete gap shows up in example programs.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope

IDE surface, inline diff UX, browser / multimodal, multi-tenant control
plane / Postgres — separate applications. This repository is the language
and interpreter. See [idea.md](idea.md).

### Super low priority

- [ ] **hwfl as MCP server** — expose check / run / approve over MCP for
      Cursor-like hosts. Distinct from the **MCP client**
      ([spec/13-mcp.md](spec/13-mcp.md)).

## Done

See [log/archive/tasks-2026-08.md](log/archive/tasks-2026-08.md) and
[log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
