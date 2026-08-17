# Status
Last updated: 2026-08-17

## Current focus
**Docs split** — user book is `manual/`; `docs/` is maintainer internals.
Working title **hwfl** remains provisional (rename next).

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **Maintainer docs pass** — deleted `language-reference.md` and
  `docs/examples/`; tutorial moved to `manual/tutorial.md`; stdlib policy
  folded into [architecture.md](architecture.md); skills / semantic-check
  plans archived
- **Omit / `latest` run-id** — continue commands take an optional id;
  missing or `latest` is newest `started_at`
- **`int.to_float` / `float.round`** — explicit same-sort conversions
- **User manual** — author book under `manual/`

## Blockers
None.

## Next up
1. Freeze or rename **hwfl** (CLI, fence, stdlib qnames, `.hwfl/`)
2. Prefer MCP / stdlib for domain tools (git, terminals, …)
3. Optional: CI; shell completions

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
