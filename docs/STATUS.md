# Status

Last updated: 2026-07-21

## Current focus

**Lab loop + exemplars** — evolve-agent hardened (fixture + operators);
next is coding-agent tools that call same-project workflows (E11).
Control plane is **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **Soft-land `max_rounds`** — agent freezes on budget exhaustion
  (`PauseAwaitingAgent`); `hwfl extend --rounds N` bumps budget and
  continues same invocation; `--interactive` prompts for extra rounds;
  bare `resume` does not resolve the gate
- **`obs.log` non-snapshotting** — spans/events only; no `persist` /
  `snapshot_seq`; infer accepts record `fields`
- **Evolve-agent v2** — seeded broken `stats` fixture; operator menu
  (`strip_warmup` / `shrink_rounds` / `drop_fs_list`); no-op patch
  rejection; gen-rotated fallbacks so `mut-g0` ≠ `mut-g1`
- Evolve-agent E23; compare mutate; E11; coding-agent chat; lab spine

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
- Structured exhausted return with `history` (secondary max_rounds path)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
