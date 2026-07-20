# Status

Last updated: 2026-07-20

## Current focus

**Post-E11 backlog reframe** — lab loop + real exemplars next; agent
substrate and observability after. Control plane is **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **E11 same-project entry call** — `qname(inputs)` → callee `main`;
  `FrInvoke` / `BranchMachine`; `examples/call-inner-workflow`
- **Coding-agent chat** — `Turn` values; `llm.agent` history in/out;
  `examples/coding-agent-chat`
- Lab spine (driver façade, FS run-store, `meta.*`, compare, Observer);
  FS tree ops; resume/approve project-hash for hwfl-server confirm

## Blockers

None.

## Next up

1. Mutate / next-generation loop on the compare spine
2. Coding-agent exemplar with tools that call workflows (E11)
3. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
4. Opt-in LangSmith-style LLM transcripts

## Deferred

- Semantic-check S4 / S6 — research; optional static fitness later
- Skills phase D (optional writer example)
- Concurrent `par` host IO (or external parallel lab processes)
- Coding-agent Tier B (index / LSP / RAG) — measured gap only
- `latest` / omit run-id; `lib/` elaboration; typed `--example`;
  alt `LlmProvider`; `hwfl init` / completions

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
