# Status
Last updated: 2026-08-11

## Current focus
**Language + interpreter** — ship in-language `lib/`, a short hello path
(`hwfl init` + tutorial entry), and keep new capabilities in MCP or `lib/`
unless they need a host op.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- Docs: clarified language + interpreter framing ([idea.md](idea.md))
- **M-21** — `exec.run` reader `forkFinally`; `ExecSpec` regressions
- **M-20** — MCP transport error invalidates cached connection
- **H-8** — `mcp.allow` + absolute-cwd gate
- MCP client + `story-writer` / `real-story-writer` examples

## Blockers
None.

## Next up
1. In-language `lib/` ([stdlib.md](stdlib.md)); factor large examples into
   multi-module projects where helpful
2. `hwfl init` and a short check → run (mock) → resume → show tutorial
3. Prefer MCP / `lib/` for domain tools (git, terminals, …)
4. Opportunistic Lows; M-3 / M-16 / M-18 only if they bite

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-18** / **M-16**; remaining Lows

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
