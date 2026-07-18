# Status

Last updated: 2026-07-18

## Current focus

Optional mutate / next-generation loop on the compare spine.
Resume/approve project-hash fix shipped (hwfl-server Phase 1).

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **Sub-cent LLM cost aggregation** — store `cost_micros` on span close;
  sum in micros; round only in `formatCostUsd`. Fixes cheap-model runs
  (e.g. DeepSeek) showing `cost: $0.00` after many sub-cent rounds
- **Resume/approve project hash** — `loadExisting` walks from `rmEntry`
  for `project.json`; project runs recompute `projectHashForModules` +
  skills from that root (not entry-only `projectHashOf`). Fixes approve
  after `awaiting_confirm` for control-plane project vs workspace layout
- **Observer hook** — `Hwfl.Obs.Observer`: live span / pause / finish;
  driver `drrObserver`; CLI `--debug` = `stderrDebugObserver`
- **Local compare lab** — `examples/compare`; `CompareSpec`
- **`meta.read_snapshot` / `meta.list_runs` / `meta.read_spans` /
  `meta.invoke`**; shared `runTarget`; run-store interface
- North-star docs; `--cost`; semantic-check S1–S3 + S5; `fs.patch`;
  skills A–C; coding-agent; P0; M0–M9

## Blockers

None.

## Next up

1. Optional: mutate / next-generation loop on the compare spine
2. Optional DB-backed run-store backend (same interface)

## Deferred

- Opt-in LangSmith-style LLM transcripts (span-linked payloads; §07 §10)
- Skills phase D (optional writer example)
- Semantic-check S4 / S6 — research only; optional static fitness later
- Coding-agent Tier A/B (git, terminals, context pre-pass; then RAG /
  MCP / LSP) — when needed as a lab benchmark
- Concurrent `par` host IO; MCP client host
- Control-plane repo (HTTP/WS, Postgres metadata, tenants) — **not** in
  hwfl; depends on the library driver + Observer above
- Optional DB-backed run-store backend (same interface; not required yet)
- Same-project module invoke sugar (`FrInvoke` / E11) — separate from
  lab `meta.invoke`

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
