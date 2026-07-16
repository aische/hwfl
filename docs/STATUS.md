# Status

Last updated: 2026-07-16

## Current focus

**Schema-guided LLM UX** — enrich builtin tool schemas with parameter
descriptions and allow optional markdown-backed schema field docs.

## Done recently

- CLI loads `.env` from cwd at startup (`Pml.Env.loadDotenv`); missing or
  unreadable files are ignored; 102 tests
- Polymorphic `obs.span` complete (E16)
- `llm.agent_object` with `schema(Out)` → `{ value: Out, rounds: Int }`

## Blockers

None.

## Next up

1. Add parameter descriptions to builtin agent tools
2. Allow optional `## schema Typename` sections in module markdown for
   `schema(T)` field descriptions
3. Streaming LLM spans
4. Optional DB-backed run store

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
