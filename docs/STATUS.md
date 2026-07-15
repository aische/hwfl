# Status

Last updated: 2026-07-15

## Current focus

**M8 complete.** Next milestone: **project-wide `pml check`** (`project.json` +
import graph). Single-file check + `meta.check_module` exist; multi-module
projects are the blocker for real dogfood splits.

## Done recently

- Semantic report: valid JSON via `json.encode`, written to
  `.pml/runs/<run-id>/semantic-report.json`; runtime `ctx` binding
- Dogfood `examples/semantic-check`: layers 0–2b in **1** module (~300 LOC) vs hwfi’s
  **74** tools (~3175 LOC)
- Pure `list` / `text` / `md` builtins; host `fs.find` + `meta.check_module`
- String/`FileRef` check unification; `==`/`</>` on String/Float (special-cases)
- E20 fixture + tests; 78 tests

## Blockers

None.

## Next up

1. **Full `pml check`** — load `project.json`, resolve qnames, build import graph,
   check all reachable modules (types, effects, cycle rejection). See
   [spec/01-modules.md](spec/01-modules.md), [spec/09-cli.md](spec/09-cli.md).
2. Float/`==` polymorphism cleanup
3. `llm.object` (E14) — check types exist; runtime + `chatResponseFormat` not wired
4. `llm.agent-object` + submit tool (deferred from M7)

**Deprioritized:** alternate `LlmProvider` backends — interface is stable; llm-simple
+ mock suffice until much later.

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
