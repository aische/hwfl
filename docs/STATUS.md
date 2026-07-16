# Status

Last updated: 2026-07-16

## Current focus

**Schema-guided LLM UX** — schema reflection now accepts optional
markdown-backed field docs from `## schema Typename` sections; next up is
streaming LLM spans.

## Done recently

- `schema(T)` now picks up optional field descriptions from `## schema Typename`
  markdown sections for named aliases; parser + runtime reflection tests added
- Builtin agent tools now advertise per-parameter JSON Schema descriptions
  (`fs.read.path`, `fs.write.path`, `fs.write.text`); regression test added
- CLI loads `.env` from cwd at startup (`Pml.Env.loadDotenv`); missing or
  unreadable files are ignored
- Polymorphic `obs.span` complete (E16)
- `llm.agent_object` with `schema(Out)` → `{ value: Out, rounds: Int }`

## Blockers

None.

## Next up

1. Streaming LLM spans
2. Optional DB-backed run store
3. Alternate `LlmProvider` backends remain low priority

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
