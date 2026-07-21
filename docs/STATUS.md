# Status

Last updated: 2026-07-21

## Current focus

**Runtime integrity (source-review High #1–#5)** — durability,
sandboxing, and “checked ≈ safe” before leaning harder on nested
invoke / E11. Findings live in repo-root `issues.md` (do not treat as
spec). Control plane remains **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **Turing-machine exemplar** — workspace tape + `tm_read` / `tm_step`;
  selftest proves tools; agent mode burns tokens
- **Zero-arg funs** — `bindParams []` + `f()` on `Unit -> T` in checker
- Soft-land `max_rounds`; `obs.log` non-snapshotting; evolve-agent v2;
  E23 / E11 / coding-agent chat / lab spine

## Blockers

None.

## Next up

1. Fix High #1–#5 (nested snapshot persist → `meta.invoke` sandbox →
   atomic store + run IDs → checker holes → schema / tool-name)
2. Credible coding-agent exemplar: tools that call workflows (E11)
3. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
4. Opt-in LangSmith-style LLM transcripts

## Deferred

- Multi-process run-store locking (until parallel external lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Structured exhausted return with `history`; TM δ skills (multiply, etc.)
- Most Medium/Low items in `issues.md` until they bite an exemplar

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
