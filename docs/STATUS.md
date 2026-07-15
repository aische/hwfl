# Status

Last updated: 2026-07-15

## Current focus

**`llm.agent_object` complete** (structured agent + synthetic `submit` tool).

## Done recently

- `llm.agent_object`: multi-transition agent loop with `schema = schema(Out)` →
  `{ value: Out, rounds: Int }`; injects terminating `submit` tool; plain-text
  finish is fatal; mixed submit rounds recover without running tools
- Surface name uses underscore (`agent_object`) — kernel idents disallow `-`
- 100 tests; semantic-check + project-check green

## Blockers

None.

## Next up

1. Streaming LLM spans
2. Optional DB-backed run store
3. Polymorphic `obs.span` check type

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
