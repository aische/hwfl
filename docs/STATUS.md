# Status

Last updated: 2026-07-15

## Current focus

**`llm.object` (E14) complete.** Next: `llm.agent-object` with synthetic submit tool.

## Done recently

- `llm.object`: host op + `chatResponseFormat` (JSON Schema) → provider → typed
  decode; Infer special-cases `schema(Out)` ⇒ result `Out`; mock fills schemas
- Runtime `schema(T)` → `VSchema`; Simple adapter uses `genObjectUntyped`
- 97 tests; semantic-check + project-check green

## Blockers

None.

## Next up

1. `llm.agent-object` + submit tool (deferred from M7)

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
