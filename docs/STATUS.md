# Status

Last updated: 2026-07-16

## Current focus

**Coding-agent readiness** — close host gaps (`exec.run`, richer FS) so a
real edit/test agent example can dogfood the runtime; then author-facing
docs (language reference + tutorial).

## Done recently

- Priority reorder: coding-agent host primitives and docs ahead of streaming,
  DB run store, skills, Servant, and MCP (see log)
- `schema(T)` optional field docs from `## schema Typename` markdown sections
- Builtin agent-tool parameter descriptions; `.env` load at CLI startup
- Polymorphic `obs.span` (E16); `llm.agent_object` + submit tool
- M0–M9 complete (check / run / step / resume / show / semantic-check dogfood)

## Blockers

None.

## Next up

1. Host gaps for coding agents: `exec.run` (runtime; already check-typed) +
   FS `list` / `edit` / `grep` (and related write helpers as needed)
2. Language reference card (keywords, builtins, host ops + signatures)
3. Real coding-agent example + short tutorial
4. CLI `--debug` / richer verbose (alongside existing `hwfl show`)
5. Streaming LLM spans
6. Semantic-check deepen (optional LLM layer; packaging)
7. Skills ([skills-plan.md](skills-plan.md))
8. Run-store interface → optional DB; later Servant API; later MCP client
9. Alternate `LlmProvider` — low priority

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
