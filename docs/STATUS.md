# Status

Last updated: 2026-07-15

## Current focus

**M7 complete** — `llm.agent` multi-transition loop + typed `tool(f)`.
Next: **M8** dogfood slim semantic-check in pml.

## Done recently

- `llm.agent` as machine `CurAgent` (model → tool* → final), snapshotted per round
- Prelude `tool(f)` builds `ToolSpec` from host ops / annotated funs / closures
- Provider `ChatRequest` carries tools + turns; mock/simple adapters updated
- E15 tests: tool round + mid-tool step/resume + agent span tree; 76 tests

## Blockers

None.

## Next up

1. **M8** — Port slim semantic-check (layers 0–2 style) in pml; compare LOC/files to hwfi
2. Later: Float/`==` polymorphism; project-wide `pml check` graph; polymorphic `obs.span` types

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
