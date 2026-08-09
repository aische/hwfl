# Status
Last updated: 2026-08-09

## Current focus
**Agent substrate** — MCP **client** (stdio) shipped: `mcp.call` /
`mcp.tools` against external servers (TS KB, web search, …). Next: git /
persistent terminals. Prefer MCP or workflow modules over new host ops.
Agent context L1+L2 (heuristic) shipped; LLM compact deferred.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **MCP client (stdio) implemented** — [spec/13-mcp.md](spec/13-mcp.md):
  `mcp.call` (+ `schema(T)`) and `mcp.tools` (filter + `bind`, schema
  stripping) as host ops; `project.json` `mcp.servers`; per-run lazy
  connection registry (`Hwfl.Runtime.Mcp`) torn down on driver exit;
  agent dispatch of MCP tools reuses the host-op tool-call path (no
  bespoke nested-machine code — see 2026-08-09 log); fixture stdio
  server + client/host-op/agent tests. hwfl-as-MCP-server parked as
  super-low priority
- **Typed `examples` + `--example`** — validates vs frontmatter types;
  `hwfl run --example` (L-18)
- **Context L1+L2** — window / `get_history` / heuristic consolidate;
  module `Hwfl.Runtime.Context`
- **Bug-report pass** — High + Medium except deferred M-3 / M-16 / M-18;
  Lows through L-15 + L-18 — see [BUG_REPORT.md](BUG_REPORT.md)

## Blockers
None.

## Next up
1. Dogfood external stdio MCP servers (TS KB, web search) against a real
   example project
2. Git (read-heavy) / persistent terminals (or MCP equivalents)
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
