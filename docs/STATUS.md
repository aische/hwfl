# Status

Last updated: 2026-07-15

## Current focus

**M5 complete** — `par` / `confirm` / `step` / `resume` / `approve` with full `machine_json`.
Next: **M6** span observability + `pml show`.

## Done recently

- Frame/CEK runtime (`Pml.Runtime.Machine` + step driver): pure crunch, host/par/confirm transitions
- `par(max)` ordered results; cooperative freeze when confirm fires inside pool
- `confirm` / `human.confirm` → `awaiting_confirm`; `pml approve --yes|--no`
- Snapshots carry `machine_json`; `meta.json` stores entry path + project hash
- CLI: `pml step|resume <workspace> <run-id>`, `pml approve … --yes|--no`, `pml run --step`
- Exit 3 on pause; exit 4 on stale project hash; 71 tests

## Blockers

None.

## Next up

1. **M6** — spans.jsonl + `pml show --tree` + redaction
2. Later: Float/`==` polymorphism; project-wide `pml check` graph; `llm.agent` (M7)

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
