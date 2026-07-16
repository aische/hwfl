# Status

Last updated: 2026-07-16

## Current focus

**Schema-guided LLM UX** — extend schema reflection with optional
markdown-backed field docs after landing builtin agent-tool parameter
descriptions.

## Done recently

- Builtin agent tools now advertise per-parameter JSON Schema descriptions
  (`fs.read.path`, `fs.write.path`, `fs.write.text`); regression test added
- CLI loads `.env` from cwd at startup (`Pml.Env.loadDotenv`); missing or
  unreadable files are ignored
- Polymorphic `obs.span` complete (E16)
- `llm.agent_object` with `schema(Out)` → `{ value: Out, rounds: Int }`

## Blockers

None.

## Next up

1. Allow optional `## schema Typename` sections in module markdown for
   `schema(T)` field descriptions
2. Streaming LLM spans
3. Optional DB-backed run store
4. Alternate `LlmProvider` backends remain low priority

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
