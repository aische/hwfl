# Status

Last updated: 2026-07-15

## Current focus

**M4 complete** — host FS sandbox, `LlmProvider`, boundary snapshots, `pml run`.
Next: **M5** `par` + `confirm` + resume / `--step`.

## Done recently

- Workspace sandbox (`Pml.Runtime.Workspace`): lexical + canonicalize containment
- Host runtime for `fs.read` / `fs.write` / `llm.chat` (same surface as check stubs)
- `LlmProvider` + mock (tests) + `Pml.Llm.Simple` (llm-simple default); workflows isolated
- Boundary snapshots after each host op under `.pml/runs/<id>/` (full kont JSON → M5)
- CLI: `pml run <module.md> [--workspace] [--input k=v…] [--llm-provider mock|simple]`
- E03/E04 mock path green; sandbox escape rejected; 66 tests

## Blockers

None.

## Next up

1. **M5** — `par` + `confirm` + resume / `--step` (full `machine_json`)
2. Later: Float/`==` polymorphism; project-wide `pml check` graph; spans/`show` (M6)

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
