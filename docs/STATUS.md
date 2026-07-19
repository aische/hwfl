# Status

Last updated: 2026-07-19

## Current focus

Optional mutate / next-generation loop on the compare spine.
Frontmatter `examples` for tooling / control-plane UI shipped.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **Frontmatter `examples`** — optional sample run inputs on modules;
  parse + key-set check; summarise dogfood; tooling metadata only
- **Deterministic FS tree ops** — `fs.mkdir`, `fs.copy` (recursive +
  optional `overwrite` / `exclude` prefixes), `fs.move`, `fs.exists`,
  `fs.stat`; compare lab materialize uses `fs.copy`
- **Sub-cent LLM cost aggregation** — store `cost_micros` on span close;
  sum in micros; round only in `formatCostUsd`
- **Resume/approve project hash** — project runs recompute
  `projectHashForModules` + skills from project root
- **Observer hook** — `Hwfl.Obs.Observer`; CLI `--debug` =
  `stderrDebugObserver`
- Local compare lab; `meta.*` run-store ops; north-star docs; `--cost`;
  semantic-check S1–S3 + S5; `fs.patch`; skills A–C; coding-agent; P0

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
- Typed validation of example values vs `TypeExpr`; CLI `--example`

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
