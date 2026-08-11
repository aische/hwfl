# Status
Last updated: 2026-08-11

## Current focus
**Language + interpreter** — short hello path (`hwfl init` + tutorial);
factor large examples into project `lib/`; prefer MCP / stdlib over new
host ops.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **Shipped `hwfl/*` stdlib** (`stdlib/`: list, option, result, string);
  pack root from `HWFL_STDLIB` / Cabal data-files / cwd walk; library
  qnames evaluate to closure records; `Ok`/`Err` in check
- **Value / let polymorphism**; docs framing; **M-21** / **M-20** / **H-8**

## Blockers
None.

## Next up
1. Factor large examples into project `lib/` / multi-module
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
