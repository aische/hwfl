# Status

Last updated: 2026-07-15

## Current focus

**M9 complete.** Next: Float/`==` polymorphism cleanup, then `llm.object` (E14),
then `llm.agent-object` with submit tool.

## Done recently

- Project-wide `pml check`: load `project.json`, discover modules by qname,
  build import graph, reject cycles, type+effect-check reachable modules
- `pml run <project-dir>` checks the full project then runs the entrypoint
- `meta.check_project` host op (workspace-relative project root)
- Fixture `test/fixtures/check-project` (+ cycle negative); 81 tests

## Blockers

None.

## Next up

1. Float/`==` polymorphism cleanup (replace M8 String/Float special-cases)
2. `llm.object` (E14) — check types exist; runtime + `chatResponseFormat` not wired
3. `llm.agent-object` + submit tool (deferred from M7)

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
