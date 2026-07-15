# Status

Last updated: 2026-07-15

## Current focus

**M3 complete** — effect lattice on load check; `pml check <module.md>`.
Next: **M4** host runtime + `LlmProvider` + snapshots.

## Done recently

- `Pml.Check.Effects`: infer residual effects; `effects:` ceiling (absent ⇒ pure)
- Host stubs: `fs`/`llm`/`human`/`exec` use `TEffFun`; `par`/`join`/`confirm` typed + Parallel/Human
- CLI: `pml check` single-module (project.json graph deferred; stderr note)
- E12 reject + summarise `[Read, Net]` green; 52 tests

## Blockers

None.

## Next up

1. **M4** — Host ops + `LlmProvider` + snapshots
2. **M5** — `par` + `confirm` + resume / `--step`
3. Later: Float/`==` polymorphism; project-wide `pml check` graph

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
