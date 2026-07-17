# Status

Last updated: 2026-07-17

## Current focus

**Streaming LLM spans** (progressive token / partial events), then
semantic-check deepen and skills.

## Done recently

- Lifecycle tutorial (`docs/tutorial.md`): module → check → run →
  approve/resume → show
- Detailed traces: per-tool-call spans (`tool:<name>`), attrs in
  `hwfl show`, CLI `--debug`
- Real coding-agent example (`examples/coding-agent`)
- P0: `exec.run`; `fs.list` / `fs.edit` / `fs.grep`; language-reference
- M0–M9 complete

## Blockers

None.

## Next up

1. Streaming LLM spans (progressive token/partial events)
2. Semantic-check deepen (optional LLM layer; packaging)
3. Skills ([skills-plan.md](skills-plan.md))
4. Run-store interface → optional DB; later Servant API; later MCP client
5. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
