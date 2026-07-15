# Status

Last updated: 2026-07-15

## Current focus

**M1 complete** — pure evaluator (big-step) + prelude builtins + E01/E02 tests.
Next: **M2** type checker.

## Done recently

- Pure eval: values/env/closures, module `fun` binding, prelude `+`/`==`/bool/…
- Infix ops elaborate to `EApp` of prelude idents (parser)
- 37 tests green (parse + load + pretty + pure eval)

## Blockers

None.

## Next up

1. **M2** — Type checker (signatures + local inference)
2. **M3** — Effects lattice + `check` CLI
3. Later: `LlmProvider` / llm-simple (M4)

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
