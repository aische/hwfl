# Status
Last updated: 2026-10-06

## Current focus
Working title **hwfl** remains provisional (rename next). User book is
`manual/`; `docs/` is maintainer internals.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **llm-simple 0.2 upgrade complete** (`task.md` Phases 1–8) — ordered
  `AssistantPart` / opaque replay; Simple adapter; snapshot `parts`
  codec (legacy decode); cache-aware pricing + catalog `capabilities`;
  ordered-replay tests; specs/manual updated; dependency `^>=0.2.0.0`
- **CI** — GitHub Actions `cabal test` on GHC 9.6 / Ubuntu; mock LLM
  only. macOS runner deferred
- **User manual** — author book under `manual/`

## Blockers
- **llm-simple 0.2 not on Hackage yet** — local builds use gitignored
  `cabal.project.local` → sibling `../llm-simple`. Clean CI / clone
  needs a Hackage release (or a temporary `source-repository-package`
  pin after the branch is published).

## Next up
1. Publish llm-simple 0.2 (or pin a remote source package) so CI is green
2. Freeze or rename **hwfl** (CLI, fence, stdlib qnames, `.hwfl/`)
3. Prefer MCP / stdlib for domain tools (git, terminals, …)

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)
- macOS CI runner
