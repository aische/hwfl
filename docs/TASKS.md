# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now — agent substrate

Prefer MCP / workflow modules over growing the host-op set.

- [ ] MCP client (tool provider behind `tool(f)` / host-op story)
- [ ] Git (read-heavy host ops or MCP) — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot
      `exec.run`
- [ ] Opt-in `exec.runtime` = `host` \| `docker` behind `exec.run`
      (spec [05-host-ops.md](spec/05-host-ops.md) §3.1) — when untrusted
      spawn bites

## Next — coding-agent / observability / research

- [ ] Workflow-driven skills coding-agent variant (separate example project)
- [ ] Opt-in LangSmith-style LLM transcripts
      ([07-observability.md](spec/07-observability.md) §10)
- [ ] Semantic-check S4 / S6; skills phase D; lab fitness `cost_micros`
- [ ] Omit / `latest` run-id for approve / choose / reply / show
- [ ] Concurrent host transitions in `par`

## Deferred bugs (fix only if they bite)

From [BUG_REPORT.md](BUG_REPORT.md); not blocking agent substrate.

- [ ] **M-3** — Skill-body prompt trust boundary (when third-party skills)
- [ ] **M-18** — Project-hash / resume UX (only if prose edits brick resume
      too often)
- [ ] **M-16** — Multi-process run-store locking (when parallel lab processes
      share a run dir)
- [ ] **Remaining Lows** — L-3–4, L-7–13, L-15, L-17–18, L-20–21, L-23, L-25
      (snapshot parse, fsync, slugs, CLI, variants, ignore/glob, …)

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

Bug-fix High + Medium (except deferred M-3 / M-16 / M-18) and selected
Lows archived in
[log/archive/tasks-2026-08.md](log/archive/tasks-2026-08.md).
Earlier milestones in
[log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
