# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now — agent substrate

Prefer MCP client / workflow modules over growing the host-op set.

- [x] **MCP client** (stdio) — [spec/13-mcp.md](spec/13-mcp.md) implemented:
      `project.json` `mcp.servers`, `mcp.call` (+ optional `schema(T)`),
      `mcp.tools` (filter + `bind`, schema stripping), agent dispatch,
      per-run lazy connect / teardown. Dogfood:
      [`examples/story-writer`](../examples/story-writer) (fixture) +
      [`examples/real-story-writer`](../examples/real-story-writer)
      (product demo: bible → outlines → chapters + assert loop) against
      external kb-mcp (`fiction.v1`). Further servers still welcome
- [ ] Git (read-heavy host ops or MCP) — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot
      `exec.run`
- [ ] Optional: real-story-writer agent tools (`world_*` via `mcp.tools`,
      bind `project_id`; filter so model cannot commit)

## Next — coding-agent / observability / research

- [ ] Workflow-driven skills coding-agent variant (separate example project)
- [ ] Opt-in LangSmith-style LLM transcripts
      ([07-observability.md](spec/07-observability.md) §10)
- [ ] Semantic-check S4 / S6; skills phase D; lab fitness `cost_micros`
- [ ] Omit / `latest` run-id for approve / choose / reply / show
- [ ] Concurrent host transitions in `par`

## Deferred bugs (fix only if they bite)

From [BUG_REPORT.md](BUG_REPORT.md); not blocking agent substrate unless noted.

- [ ] **M-21** — `exec.run` reader-thread hang if `readCapped` throws
- [ ] **M-3** — Skill-body prompt trust boundary (when third-party skills)
- [ ] **M-18** — Project-hash / resume UX (only if prose edits brick resume
      too often)
- [ ] **M-16** — Multi-process run-store locking (when parallel lab processes
      share a run dir)
- [ ] **Remaining Lows** — L-4, L-9–10, L-12, L-17, L-20–21, L-23,
      L-25–27 (fsync, CLI, ignore/glob, confirmOf, mega-modules, …)

## Low priority

- [ ] `consolidate = "llm"` — Context L2 LLM summarizer + lasting
      `context` seed/return (pins/summary/watermark); update host-op /
      language-reference signatures. Design notes:
      [log/2026-08.md](log/2026-08.md) (2026-08-08 — agent context layers /
      coding-agent-chat lasting context)
- [ ] Opt-in `exec.runtime` = `host` \| `docker` behind `exec.run`
      (spec [05-host-ops.md](spec/05-host-ops.md) §3.1) — when untrusted
      spawn bites
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] In-language `lib/` modules per [stdlib.md](stdlib.md)
- [ ] `hwfl init` / shell completions

## Future / nice-to-have (coding-agent Tier B)

Delay until a measured coding-agent gap.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, browser / multimodal — control-plane or
other product; hwfl stays the orchestration kernel. Control plane /
Postgres live in **hwfl-server**, not here. See [idea.md](idea.md).

### Super low priority

- [ ] **hwfl as MCP server** — expose check / run / approve (etc.) over
      MCP for Cursor and similar hosts. Distinct from the **MCP client**
      in Now ([spec/13-mcp.md](spec/13-mcp.md)). Older log notes that
      bundled this with Servant are outdated for priority; do not start
      before the client dogfoods external servers.

## Done

Context L1+L2 (heuristic), bug-fix High + Medium (except deferred
M-3 / M-16 / M-18), **H-8** MCP allowlist, **M-20** MCP timeout reconnect, selected Lows through L-15 +
L-18, and typed `--example` archived in
[log/archive/tasks-2026-08.md](log/archive/tasks-2026-08.md).
Earlier milestones in
[log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
