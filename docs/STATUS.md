# Status
Last updated: 2026-08-17

## Current focus
**CLI UX** — omit / `latest` run-id for continue commands. Prefer MCP /
stdlib for new domain tools.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **Omit / `latest` run-id** — `step` / `resume` / `approve` / `choose` /
  `reply` / `extend` / `show` take an optional run id; missing or `latest`
  is newest `started_at`. `latest` is reserved on create
- **`int.to_float` / `float.round`** — explicit same-sort conversions in
  the pure prelude (`trunc` / `floor` / `ceil` / round-half-to-even);
  overflow of `int.to_float` traps
- **User manual pass** — dropped implementation/spec leaks
- **M-18 structural project hash** — prose edits no longer brick resume
- **L-17 curried `obs.span` typing**; default `--workspace`; short hello
  path; shipped `hwfl/*` stdlib; value / let polymorphism; **M-21** /
  **M-20** / **H-8**; **L-20** / **L-26**

## Blockers
None.

## Next up
1. Prefer MCP / stdlib for domain tools (git, terminals, …)
2. Optional: shell completions

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
