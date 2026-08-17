# 10 — Acceptance

M0–M9 (syntax through project-wide `hwfl check`) completed 2026-07-15.
The milestone checklist is archived in
[log/archive/tasks-2026-07.md](../log/archive/tasks-2026-07.md).

## 1. Fitness metrics (ongoing)

| Metric | Target intuition |
| ------ | ---------------- |
| Author files for semantic-check-class workflow | ≪ hwfi’s ~70 tools; aim ≤ 15 modules |
| Resume mid-LLM | Exact stack restore; at-most duplicate that call |
| Failed-run comprehension | `hwfl show --tree` sufficient without reading JSON dumps |
| Provider swap | Second adapter selectable; one test green — **low priority**; `LlmProvider` record already ships |

## 2. Shipped past M9

Skills A–C (`skill.discover` / `skill.load`); streaming LLM spans
([07-observability.md](07-observability.md) §9); agent context L1+L2
heuristic ([05-host-ops.md](05-host-ops.md)); MCP stdio client
([13-mcp.md](13-mcp.md)). Optional later: skills phase D; semantic-check
S4/S6; `consolidate = "llm"`; second LLM adapter.

## 3. Explicit non-acceptance

- Shipping a second step-DSL
- Workflows importing llm-simple types
- Resume based on content-addressed step cache
- Unsandboxed filesystem
