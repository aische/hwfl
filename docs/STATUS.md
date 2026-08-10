# Status
Last updated: 2026-08-10

## Current focus
**Agent substrate** — MCP client dogfooded; product-demo story pipeline
in `examples/real-story-writer` (kb-mcp world model). Fixture
`examples/story-writer` stays the regression harness. Next: git /
persistent terminals. Prefer MCP or workflow modules over new host ops.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **Audit follow-up** — BUG_REPORT amended: **H-8** (MCP allowlist gap),
  **M-20** (timeout-wedged MCP conn; probe), **M-21** (`exec` reader
  hang), L-26/L-27; M-3/M-16/M-18 reconfirmed
- **real-story-writer** — layered KB repair + `strict_kb`; smoke fixture
  unchanged; `story-writer` kept
- **MCP dogfood** — fixture + live extract loop; stdio client per
  [spec/13-mcp.md](spec/13-mcp.md)
- Context L1+L2 (heuristic); typed `--example`; prior High + Medium
  except deferred M-3 / M-16 / M-18

## Blockers
None.

## Next up
1. Git (read-heavy) / persistent terminals (or MCP equivalents)
2. Prefer soon: **H-8** MCP allowlist before untrusted projects
3. Optional: agent path with `world_*` + `mcp.tools` bind (filter commit)
4. Context L2 follow-up: `consolidate = "llm"` + lasting `context`
5. Opportunistic M-20 / M-21 / Lows; M-3 / M-18 only if they bite

## Deferred
- **`consolidate = "llm"`** — LLM compact + lasting agent `context`
- **hwfl as MCP server** — expose runtime to Cursor (super low priority)
- **H-8** / **M-20** / **M-21** / **M-3** / **M-18** / **M-16** — see
  TASKS / BUG_REPORT
- Remaining Lows; Docker `exec.runtime`; semantic-check S4/S6; skills
  phase D; concurrent `par` host IO; Tier B; `latest` run-id; `lib/`

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
