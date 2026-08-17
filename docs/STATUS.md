# Status
Last updated: 2026-08-17

## Current focus
**User manual** — author-facing `manual/` book. Spec/backlog voice stripped
from the worst pages; remaining editorial nits are optional.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **User manual pass** — dropped implementation/spec leaks (`agHistory`,
  L1/L2, kernel AST, `forall e`, Docker, `on_error`, prelude stub, “what
  this book is not”) and a few unclear bits (`try`/`catch`, resume, MCP
  sandbox)
- **M-18 structural project hash** — prose edits no longer brick resume
- **L-17 curried `obs.span` typing**
- **Default `--workspace`**; **short hello path**; factored large examples
- **Shipped `hwfl/*` stdlib**; **Value / let polymorphism**; **M-21** /
  **M-20** / **H-8**; **L-20** / **L-26**

## Blockers
None.

## Next up
1. Prefer MCP / stdlib for domain tools (git, terminals, …)
2. Optional: shell completions; omit / `latest` run-id

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
