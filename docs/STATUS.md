# Status

Last updated: 2026-07-15

## Current focus

**Polymorphic `obs.span` complete** (check return type = body type; E16).

## Done recently

- Polymorphic `obs.span`: Infer special-cases `(name, fun () -> a) -> a`
  (curried or two-arg); runtime region/span unchanged; empty `fun ()`
  bindings fixed; 102 tests
- `llm.agent_object`: multi-transition agent loop with `schema = schema(Out)` →
  `{ value: Out, rounds: Int }`; injects terminating `submit` tool; plain-text
  finish is fatal; mixed submit rounds recover without running tools
- Surface name uses underscore (`agent_object`) — kernel idents disallow `-`

## Blockers

None.

## Next up

1. Streaming LLM spans
2. Optional DB-backed run store

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
