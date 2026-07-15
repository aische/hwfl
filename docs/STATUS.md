# Status

Last updated: 2026-07-15

## Current focus

**M6 complete** — span observability + `pml show`.
Next: **M7** `llm.agent` + typed tool functions.

## Done recently

- Append-only `spans.jsonl` (open/close) — O(1) per transition, no full-trace rebuild
- Module + host spans nested; `obs.log` / `obs.span` runtime; confirm span across pause
- Redaction: `VSecret`, host attrs (prompt lengths only), sensitive JSON keys
- CLI: `pml show <ws> <run-id> [--tree|--spans|--snapshot] [--filter PREFIX]`
- Snapshot carries `span_stack` / `span_counter` for resume nesting; 74 tests

## Blockers

None.

## Next up

1. **M7** — `llm.agent` multi-transition loop + typed tools from functions
2. Later: Float/`==` polymorphism; project-wide `pml check` graph; polymorphic `obs.span` types

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
