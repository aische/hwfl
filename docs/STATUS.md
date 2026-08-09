# Status
Last updated: 2026-08-09

## Current focus
**Agent substrate** — MCP client dogfooded via `examples/story-writer`
(external kb-mcp). Next: git / persistent terminals. Prefer MCP or
workflow modules over new host ops. Agent context L1+L2 (heuristic)
shipped; LLM compact deferred.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **MCP dogfood** — `examples/story-writer`: fixture mode seeds
  `fiction.v1`, dry-runs a planted dead+located clash via
  `kb_assert_delta`, commits a clean chapter, snapshots canon (no LLM).
  Live mode: write → extract → dry_run / one regen → commit
- **MCP client (stdio)** — [spec/13-mcp.md](spec/13-mcp.md); see prior
  log. Companion kb-mcp tweaks: assert findings are not MCP `isError`;
  empty claim object arms scrubbed for hwfl interop
- Context L1+L2 (heuristic); typed `--example`; bug-fix High + Medium
  except deferred M-3 / M-16 / M-18

## Blockers
None.

## Next up
1. Git (read-heavy) / persistent terminals (or MCP equivalents)
2. Optional: story-writer agent path with `world_*` + `mcp.tools` bind
3. Context L2 follow-up: `consolidate = "llm"` + lasting `context`
4. Skills coding-agent variant when substrate exists
5. Opportunistic Lows; M-3 / M-18 only if they bite

## Deferred
- **`consolidate = "llm"`** — LLM compact + lasting agent `context`
- **hwfl as MCP server** — expose runtime to Cursor (super low priority)
- **M-3** / **M-18** / **M-16** — see TASKS
- Remaining Lows; Docker `exec.runtime`; semantic-check S4/S6; skills
  phase D; concurrent `par` host IO; Tier B; `latest` run-id; `lib/`

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
