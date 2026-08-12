# Status
Last updated: 2026-08-11

## Current focus
**Polish + low-hanging fixes** — five targeted items (default `--workspace`,
M-18 structural project hash, L-17 `obs.span` curried typing, L-20 ignore
negation, L-26 `confirmOf` fail-closed). See TASKS.md §Now.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **Short hello path** — `hwfl init` scaffolds LLM + confirm project;
  [tutorial.md](tutorial.md) is init → check → run (mock) → approve → show
- **Factored large examples** — `semantic-check` / `real-story-writer` into
  `lib/*` + `types/main`; import brings type aliases; `VLibFun` for library
  exports (snapshot-safe); module-path run/check loads enclosing project
- **Shipped `hwfl/*` stdlib** (`stdlib/`: list, option, result, string);
  pack root from `HWFL_STDLIB` / Cabal data-files / cwd walk
- **Value / let polymorphism**; docs framing; **M-21** / **M-20** / **H-8**

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
- **M-3** / **M-18** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
