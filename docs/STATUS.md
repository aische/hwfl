# Status
Last updated: 2026-08-11

## Current focus
**Language + interpreter** — ship in-language `hwfl/*` stdlib (+ project
`lib/`), short hello path (`hwfl init` + tutorial), prefer MCP / stdlib
over new host ops.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **Value / let polymorphism** in check (`List<a>`, `(a) -> b`, schemes,
  unify); effect polymorphism still deferred
- Docs: polymorphism-before-stdlib; language + interpreter framing
- **M-21** / **M-20** / **H-8**; MCP client + story-writer examples

## Blockers
None.

## Next up
1. Ship stdlib pack (`hwfl/*`); resolve root from `HWFL_STDLIB` or a
   sensible default; use from examples; factor large mains into project
   `lib/` where helpful
2. `hwfl init` and a short check → run (mock) → resume → show tutorial
3. Prefer MCP / stdlib for domain tools (git, terminals, …)
4. Opportunistic Lows; M-3 / M-16 / M-18 only if they bite

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-18** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
