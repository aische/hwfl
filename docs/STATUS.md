# Status

Last updated: 2026-07-19

## Current focus

Optional mutate / next-generation loop on the compare spine.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **Type/parse error locations** — located `Expr`/`Decl`; fence-absolute
  `line:col` on check errors; JSON `line`/`column`; `meta.check_module`
  messages include positions
- **CLI `--dump`** — opt-in llm-simple request/response JSON under
  `./dumps` (was always on); distinct from `--debug` spans
- **Author-doc noise pass** — architecture / idea / stdlib / langref
- **Root README** — overview + coding-agent quick start
- **Frontmatter `examples`** — sample run inputs; tooling metadata only
- **Deterministic FS tree ops** — `fs.mkdir` / `copy` / `move` / `exists`
  / `stat`; compare lab materialize uses `fs.copy`
- Local compare lab; `meta.*`; `--cost`; Observer `--debug`

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
