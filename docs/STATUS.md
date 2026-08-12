# Status
Last updated: 2026-08-12

## Current focus
**Polish + low-hanging fixes** — five targeted items (default `--workspace`,
M-18 structural project hash, L-17 `obs.span` curried typing, L-20 ignore
negation, L-26 `confirmOf` fail-closed). See TASKS.md §Now.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **M-18 structural project hash** — `projectHashForModules` now SHA-256
  over `lmFrontmatter` + `lmBody` only; `lmProseBody`/`lmSections` excluded;
  `cryptohash-sha256` added; prose edits no longer brick resume
- **Default `--workspace`** — target project dir auto-derives workspace
- **Short hello path** — `hwfl init` scaffolds LLM + confirm project
- **Factored large examples** — `semantic-check` / `real-story-writer` into
  `lib/*` + `types/main`; `VLibFun` for library exports (snapshot-safe)
- **Shipped `hwfl/*` stdlib**; **Value / let polymorphism**; **M-21** / **M-20** / **H-8**

## Blockers
None.

## Next up
1. Five Now items (see TASKS.md §Now)
2. Prefer MCP / stdlib for domain tools (git, terminals, …)
3. Optional: shell completions; omit / `latest` run-id

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
