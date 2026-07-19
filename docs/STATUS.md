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

- **Author-doc hygiene** — strip milestone / plan / task-ID noise from
  language-reference, tutorial, idea, architecture, stdlib; leave
  STATUS / TASKS / plans / specs as the scaffolding layer
- **Root README** — overview + coding-agent quick start
- **Frontmatter `examples`** — sample run inputs; tooling metadata only
- **Deterministic FS tree ops** — `fs.mkdir` / `copy` / `move` / `exists`
  / `stat`; compare lab materialize uses `fs.copy`
- **Sub-cent LLM cost** · resume project hash · Observer `--debug`
- Local compare lab; `meta.*`; `--cost`; semantic-check / skills /
  coding-agent host gaps

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
