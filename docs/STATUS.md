# Status

Last updated: 2026-07-15

## Current focus

**M2 complete** — bidirectional type checker, module I/O vs `main`, `schema(T)`.
Next: **M3** effects lattice + `check` CLI.

## Done recently

- `Pml.Check.*`: env, prelude stubs (`fs`/`llm`), infer/check, module I/O, schema
- `schema(T)` parse + JSON Schema reflection (records/lists/bases)
- Frontmatter inputs/outputs elaborate missing `main` annotations
- 50 tests green (parse + load + pretty + pure eval + check)

## Blockers

None.

## Next up

1. **M3** — Effects lattice + `pml check` CLI
2. **M4** — Host ops + `LlmProvider` + snapshots
3. Later: Float/`==` polymorphism; width subtyping if needed

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
