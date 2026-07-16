# Status

Last updated: 2026-07-16

## Current focus

**Coding-agent dogfood** — P0 host gaps closed; next is a real edit/test
agent example + tutorial, then CLI `--debug`.

## Done recently

- P0: runtime `exec.run` (allowlist + `exec.confirm` from `project.json`)
- P0: `fs.list` / `fs.edit` / `fs.grep` (+ agent tool metadata)
- P0: [language-reference.md](language-reference.md) card
- Priority reorder: coding-agent host primitives ahead of streaming / DB /
  skills / Servant / MCP
- `schema(T)` optional field docs; builtin tool descriptions; `.env` load
- M0–M9 complete

## Blockers

None.

## Next up

1. Real coding-agent example (sandbox edit / test loop using exec + FS)
2. Tutorial: module → `check` → `run` → `resume` → `show`
3. CLI `--debug` (and complete `-v` / `--json` where thin)
4. Streaming LLM spans
5. Semantic-check deepen (optional LLM layer; packaging)
6. Skills ([skills-plan.md](skills-plan.md))
7. Run-store interface → optional DB; later Servant API; later MCP client
8. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
