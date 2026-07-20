# Status

Last updated: 2026-07-20

## Current focus

**Lab loop + exemplars** — evolve-agent lab shipped; next is a
coding-agent exemplar whose tools call same-project workflows (E11).
Control plane is **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **Evolve-agent lab (E23)** — score slim coding-agent genomes on a fixed
  Python task; `llm.object` mutate + structural fallback; N-gen elite+child;
  fitness = task `ok` then fewer `llm.*` spans; isolated trial dirs
- Compare mutate loop; E11 entry call; coding-agent chat; lab spine

## Blockers

None.

## Next up

1. Credible coding-agent exemplar: tools that call workflows (E11)
2. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
3. Opt-in LangSmith-style LLM transcripts
4. Optional: sum `cost_micros` in lab fitness; semantic-check static filter

## Deferred

- Semantic-check S4 / S6 — research; optional static fitness later
- Skills phase D (optional writer example)
- Concurrent `par` host IO (or external parallel lab processes)
- Coding-agent Tier B (index / LSP / RAG) — measured gap only
- `latest` / omit run-id; `lib/` elaboration; typed `--example`;
  alt `LlmProvider`; `hwfl init` / completions

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
