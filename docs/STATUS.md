# Status

Last updated: 2026-07-16

## Current focus

**CLI ergonomics** — `.env` auto-load for provider keys.

## Done recently

- CLI loads `.env` from cwd at startup (`Pml.Env.loadDotenv`); missing or
  unreadable files are ignored; 102 tests
- Polymorphic `obs.span` complete (E16)
- `llm.agent_object` with `schema(Out)` → `{ value: Out, rounds: Int }`

## Blockers

None.

## Next up

1. Streaming LLM spans
2. Optional DB-backed run store

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
