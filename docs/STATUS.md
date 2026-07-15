# Status

Last updated: 2026-07-15

## Current focus

**Float/`==` overloading cleanup complete.** Next: `llm.object` (E14), then
`llm.agent-object` with submit tool.

## Done recently

- Coherent operator overloading (`Pml.Check.Overload`): same-sort arith,
  comparable/`ord` dispatch, dedicated `String`≅`FileRef` path coercibility
- Runtime eq/ord/arith aligned with check; M8 Infer special-cases removed
- 94 tests; semantic-check + project-check green

## Blockers

None.

## Next up

1. `llm.object` (E14) — check types exist; runtime + `chatResponseFormat` not wired
2. `llm.agent-object` + submit tool (deferred from M7)

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
