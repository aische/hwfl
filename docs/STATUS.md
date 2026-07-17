# Status

Last updated: 2026-07-17

## Current focus

**Author-facing docs** — coding-agent example shipped; next is the tutorial
(`check` → `run` → `resume` → `show`), then CLI `--debug`.

## Done recently

- Real coding-agent example: universal create/fix agent via
  `llm.agent_object` + FS + `exec.run` (`examples/coding-agent`)
- `fs.find` agent-tool eligible (explore before write)
- P0: runtime `exec.run`; `fs.list` / `fs.edit` / `fs.grep`; language-reference
- M0–M9 complete

## Blockers

None.

## Next up

1. Tutorial: module → `check` → `run` → `resume` → `show`
2. CLI `--debug` (and complete `-v` / `--json` where thin)
3. Streaming LLM spans
4. Semantic-check deepen (optional LLM layer; packaging)
5. Skills ([skills-plan.md](skills-plan.md))
6. Run-store interface → optional DB; later Servant API; later MCP client
7. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
