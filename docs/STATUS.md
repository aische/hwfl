# Status

Last updated: 2026-07-17

## Current focus

Meta host ops for nested lab runs (`meta.invoke`, list/read spans).
Run-store interface + library driver are in place.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **Run-store interface** (`Hwfl.Runtime.Store`: `RunStoreBackend` + FS
  backend; list / read meta / spans / snapshot; opaque `RunStore`)
- Driver queries: `driverListRuns` / `driverReadMeta` /
  `driverReadSpans` / `driverReadSnapshot`
- **Library driver façade** (`Hwfl.Driver`: check / run / step / resume /
  approve / show); CLI thinned to flags + presentation
- North-star docs: lab + library façade; Servant out of this repo
- **`--cost`**; semantic-check S1–S3 + S5; `fs.patch`; streaming spans;
  skills A–C; coding-agent; P0; M0–M9

## Blockers

None.

## Next up

1. Meta for nested lab runs: `meta.invoke`, `meta.list_runs`,
   `meta.read_spans` (+ careful snapshot)
2. Local genetic prototype — N temp projects × workspace fixture ×
   score (CLI or parent workflow)
3. Observer hook for live span / pause events (CLI `--debug` today;
   WS/SSE maps onto this in the control-plane repo)

## Deferred

- Skills phase D (optional writer example)
- Semantic-check S4 / S6 — research only; optional static fitness later
- Coding-agent Tier A/B (git, terminals, context pre-pass; then RAG /
  MCP / LSP) — when needed as a lab benchmark
- Concurrent `par` host IO; MCP client host
- Control-plane repo (HTTP/WS, Postgres metadata, tenants) — **not** in
  hwfl; depends on the library driver above
- Optional DB-backed run-store backend (same interface; not required yet)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
