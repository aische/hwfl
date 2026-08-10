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
- **M-20** — On MCP transport timeout/error, invalidate cached
  connection (kill process group) and reconnect lazily on next call;
  regression in `McpSpec`
- **H-8** — `mcp.allow` + basename-only command; absolute `cwd` gated by
  `mcp.allow_absolute_cwd` (default false); fail closed at load + spawn
- **Audit follow-up** — BUG_REPORT: M-21 / L-26–27 open; M-3 / M-16 /
  M-18 reconfirmed
- **real-story-writer** — layered KB repair + `strict_kb`; smoke fixture
  unchanged; `story-writer` kept
- **MCP dogfood** — fixture + live extract loop; stdio client per
  [spec/13-mcp.md](spec/13-mcp.md)
- Context L1+L2 (heuristic); typed `--example`

## Blockers
None.

## Next up
1. Git (read-heavy) / persistent terminals (or MCP equivalents)
2. Optional: agent path with `world_*` + `mcp.tools` bind (filter commit)
3. Context L2 follow-up: `consolidate = "llm"` + lasting `context`
4. Opportunistic M-21 / Lows; M-3 / M-18 only if they bite

## Deferred
- **`consolidate = "llm"`** — LLM compact + lasting agent `context`
- **hwfl as MCP server** — expose runtime to Cursor (super low priority)
- **M-21** / **M-3** / **M-18** / **M-16** — see TASKS / BUG_REPORT
- Remaining Lows; Docker `exec.runtime`; semantic-check S4/S6; skills
  phase D; concurrent `par` host IO; Tier B; `latest` run-id; `lib/`

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
