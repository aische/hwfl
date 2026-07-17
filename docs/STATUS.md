# Status

Last updated: 2026-07-17

## Current focus

Skills phases A–C landed. Next: streaming LLM spans, then
semantic-check deepen / phase D extraction dogfood.

## Done recently

- Skills A–C: `skills/` catalog, `skill.discover` / `skill.load`, agent
  mid-loop load + resume fields + budgets (`examples/skills`)
- Lifecycle tutorial (`docs/tutorial.md`)
- Detailed traces: per-tool-call spans, `hwfl show`, CLI `--debug`
- Real coding-agent example (`examples/coding-agent`)
- P0: `exec.run`; `fs.list` / `fs.edit` / `fs.grep`; language-reference
- M0–M9 complete

## Blockers

None.

## Next up

1. Streaming LLM spans (progressive token/partial events)
2. Semantic-check deepen (optional LLM layer; packaging)
3. Skills phase D (optional) — writer workflow; no hidden `skill.extract`
4. Run-store interface → optional DB; later Servant API; later MCP client
5. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
