# Status
Last updated: 2026-10-06

## Current focus
Upgrade hwfl to **llm-simple 0.2** (`task.md`): ordered assistant
content, opaque replay state, cache usage/pricing. Working title
**hwfl** remains provisional (rename next). User book is `manual/`;
`docs/` is maintainer internals.

## North star
Language + durable interpreter (library + CLI). See [idea.md](idea.md).

## Done recently
- **llm-simple 0.2 Phase 1–3** — engine-owned ordered `AssistantPart` /
  opaque thinking; parts-authoritative `ProviderResult`; Simple adapter
  maps `ContentPart`/`PartBody`; runtime stores exact `prParts`,
  projections for tools/final text; transcript/sizing omit opaque
- **CI** — GitHub Actions `cabal test` on GHC 9.6 / Ubuntu; mock LLM
  only. macOS runner deferred
- **User manual** — author book under `manual/`

## Blockers
None.

## Next up
1. llm-simple 0.2 Phases 4–8 — snapshot codec, cache pricing, catalog
   capabilities, ordered-replay tests, docs
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
