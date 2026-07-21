# Status

Last updated: 2026-07-21

## Current focus

**Lab loop + exemplars** — evolve-agent hardened; coding-agent tools that
call same-project workflows (E11) still next. Control plane is
**hwfl-server**. Side exemplar: Turing-machine agent stress test.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **Turing-machine exemplar** — `examples/turing-machine`: workspace tape
  (`machine/{state,head,cells}`), `tm_read` / `tm_step`, unary-add δ in
  system prompt; `mode=selftest` proves tools; agent mode burns tokens
- **Zero-arg funs** — `bindParams []` + `f()` on `Unit -> T` in checker
- Soft-land `max_rounds`; `obs.log` non-snapshotting; evolve-agent v2;
  E23 / E11 / coding-agent chat / lab spine

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
- TM instruction skills for more δ tables (multiply, etc.)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
