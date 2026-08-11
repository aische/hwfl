# Status
Last updated: 2026-08-11

## Current focus
**Language + interpreter** — **polymorphism next** (unblocks a real
stdlib), then ship in-language `hwfl/*` stdlib + project `lib/`, short
hello path (`hwfl init` + tutorial), prefer MCP / stdlib over new host
ops.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- Docs: polymorphism-before-stdlib; stdlib root via `HWFL_STDLIB` +
  default ([stdlib.md](stdlib.md))
- Docs: language + interpreter framing ([idea.md](idea.md))
- **M-21** / **M-20** / **H-8**; MCP client + story-writer examples

## Blockers
None.

## Next up
1. **Value / let polymorphism** in check (+ eval as needed) so
   `hwfl/list.map` etc. are one function — see [stdlib.md](stdlib.md),
   [spec/03-types.md](spec/03-types.md)
2. Ship stdlib pack (`hwfl/*`); resolve root from `HWFL_STDLIB` or a
   sensible default; use from examples; factor large mains into project
   `lib/` where helpful
3. `hwfl init` and a short check → run (mock) → resume → show tutorial
4. Prefer MCP / stdlib for domain tools (git, terminals, …)
5. Opportunistic Lows; M-3 / M-16 / M-18 only if they bite

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-18** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
