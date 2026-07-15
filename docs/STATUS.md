# Status

Last updated: 2026-07-15

## Current focus

**M8 complete** — slim semantic-check dogfood (layers 0–2b) in one pml module.
Next: project-wide `pml check` graph / Float–`==` polish as needed.

## Done recently

- Dogfood `examples/semantic-check`: layers 0–2b in **1** module (~300 LOC) vs hwfi’s
  **74** tools (~3175 LOC)
- Pure `list` / `text` / `md` builtins; host `fs.find` + `meta.check_module`
- String/`FileRef` check unification; `==`/`</>` on String/Float
- E20 fixture + tests; 78 tests

## Blockers

None.

## Next up

1. Full `pml check` project.json + import graph
2. Float/`==` polymorphism cleanup (partially unblocked by M8 special-cases)
3. Alternate `LlmProvider` as swap proof

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
