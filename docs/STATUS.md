# Status

Last updated: 2026-07-18

## Current focus

Local genetic / compare prototype next.
`meta.invoke` + `meta.list_runs` / `meta.read_spans` / `meta.read_snapshot`
shipped.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **`meta.read_snapshot`** — redacted run snapshot Json via Store +
  `redactJson` (never raw cleartext `snapshot.json`)
- **`meta.list_runs` / `meta.read_spans`** — workspace-relative run-store
  reads; recoverable `{ ok, …, error }`; optional span filters
- **`meta.invoke`** — nested `runTarget` / driverRun; workspace-relative
  `project` + `workspace` (+ optional `inputs`); returns
  `{ ok, run_id, status, outcome, error }`
- Shared **`runTarget`** in `Hwfl.Runtime.Run` (Driver thinned to wrap it)
- Run-store interface + library driver façade
- North-star docs: lab + library façade; Servant out of this repo
- **`--cost`**; semantic-check S1–S3 + S5; `fs.patch`; streaming spans;
  skills A–C; coding-agent; P0; M0–M9

## Blockers

None.

## Next up

1. Local genetic prototype — N temp projects × workspace fixture ×
   score (CLI or parent workflow)
2. Observer hook for live span / pause events (CLI `--debug` today;
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
- Same-project module invoke sugar (`FrInvoke` / E11) — separate from
  lab `meta.invoke`

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
