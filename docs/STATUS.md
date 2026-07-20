# Status

Last updated: 2026-07-20

## Current focus

**Lab loop + exemplars** — mutate loop shipped on compare; next is a
coding-agent exemplar whose tools call same-project workflows (E11).
Control plane is **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **Compare mutate / next-gen loop** — gen0 lean vs rich → `fs.patch`
  `rich`→`stripped` → gen1 elite+mutant; no new host ops
- **E11 same-project entry call** — `FrInvoke` / `BranchMachine`;
  `examples/call-inner-workflow`
- **Coding-agent chat** — `Turn` values; `llm.agent` history in/out
- Lab spine (driver, FS run-store, `meta.*`, Observer); FS tree ops

## Blockers

None.

## Next up

1. Credible coding-agent exemplar: tools that call workflows (E11)
2. Richer lab fitness (outcome + cost; optional semantic-check filter)
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
