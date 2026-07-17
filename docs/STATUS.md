# Status

Last updated: 2026-07-17

## Current focus

**Author-facing docs** — tutorial (`check` → `run` → `resume` → `show`).

## Done recently

- Detailed traces: per-tool-call spans (`tool:<name>`), attrs in
  `hwfl show`, CLI `--debug` (live span open/close + end tree)
- Real coding-agent example (`examples/coding-agent`)
- P0: `exec.run`; `fs.list` / `fs.edit` / `fs.grep`; language-reference
- M0–M9 complete

## Blockers

None.

## Next up

1. Tutorial: module → `check` → `run` → `resume` → `show`
2. Streaming LLM spans (progressive token/partial events)
3. Semantic-check deepen (optional LLM layer; packaging)
4. Skills ([skills-plan.md](skills-plan.md))
5. Run-store interface → optional DB; later Servant API; later MCP client
6. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
