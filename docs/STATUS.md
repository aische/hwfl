# Status

Last updated: 2026-07-17

## Current focus

Library driver + run-store interface (lab spine). CLI stays one frontend.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- North-star docs: lab + library façade; Servant out of this repo
- **`--cost`**; semantic-check S1–S3 + S5; `fs.patch`; streaming spans;
  skills A–C; coding-agent; P0; M0–M9

## Blockers

None.

## Next up

1. Library driver façade (check / run / step / resume / approve / show)
   shared by CLI — stable enough for a future control-plane app
2. Run-store **interface** over `.hwfl/runs` (FS backend first; no
   Postgres required yet)
3. Meta for nested lab runs: `meta.invoke`, `meta.list_runs`,
   `meta.read_spans` (+ careful snapshot)
4. Local genetic prototype — N temp projects × workspace fixture ×
   score (CLI or parent workflow)

## Deferred

- Skills phase D (optional writer example)
- Semantic-check S4 / S6 — research only; optional static fitness later
- Coding-agent Tier A/B (git, terminals, context pre-pass; then RAG /
  MCP / LSP) — when needed as a lab benchmark
- Concurrent `par` host IO; MCP client host
- Control-plane repo (HTTP/WS, Postgres metadata, tenants) — **not** in
  hwfl; depends on the library driver above
- Optional DB-backed run-store backend (only after the interface exists)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
