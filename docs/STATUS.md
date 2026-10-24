# Status
Last updated: 2026-10-24

## Current focus
Working title **hwfl** remains provisional (rename next). User book is
`manual/`; `docs/` is maintainer internals.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **llm-simple 0.4** — dependency `^>=0.4.0.0` from Hackage; new
  `ResponseBlocked` mapped to `OtherProviderError`; dropped
  `ToolLoopExceeded` from the adapter; suite green on Hackage 0.4
- **llm-simple 0.3** — dependency `^>=0.3.0.0` from Hackage;
  `StreamAttemptReset` → `DeltaAttemptReset` + obs `attempt_reset`;
  fixture `LLMGateway` image fields; suite green on Hackage 0.3
- **llm-simple 0.2 upgrade** — ordered `AssistantPart` / opaque replay;
  Simple adapter; snapshot `parts`; cache-aware pricing
- **CI** — GitHub Actions `cabal test` on GHC 9.6 / Ubuntu; mock LLM
  only. macOS runner deferred
- **User manual** — author book under `manual/`

## Blockers
None.

## Next up
1. Freeze or rename **hwfl** (CLI, fence, stdlib qnames, `.hwfl/`)
2. Prefer MCP / stdlib for domain tools (git, terminals, …)

## Deferred
- Git / persistent terminals (MCP first)
- `consolidate = "llm"` + lasting agent `context`
- hwfl as MCP server
- Lab fitness / coding-agent Tier B / Docker `exec.runtime`
- **M-3** / **M-16**; remaining Lows
- Effect polymorphism (`forall e. …`)
- macOS CI runner
