# Status

Last updated: 2026-07-20

## Current focus

**E11 same-project entry call** (`FrInvoke`) — spec locked; implement
`qname(inputs)` → callee `main` in the same run.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates) and a **separate** remote
control plane. Coding-agent and semantic-check are benchmarks / research,
not the product. See [idea.md](idea.md).

## Done recently

- **Coding-agent chat** — `Turn` values; `llm.agent` / `llm.agent_object`
  optional `history` in + `history` out; `examples/coding-agent-chat`
- **FrInvoke / E11 spec locked** — same-project `qname(inputs)` →
  callee `main`; one nest model; no Meta tax (§01 §3.2, §06 §3.1)
- **Workflow chat** — `human.ask` detail carries prior assistant reply;
  `llm.chat_messages`; `examples/chat`
- **CLI `--interactive`** — TTY stdin loop over confirm / choice / ask
- **`human.choice`** — N-way gate; `examples/choose` / `agent-choice.md`
- Type/parse error locations; CLI `--dump`; FS tree ops; compare lab;
  `meta.*`; Observer `--debug`

## Blockers

None.

## Next up

1. E11: implement same-project entry call (`FrInvoke`) per locked spec
2. Optional: mutate / next-generation loop on the compare spine
3. Tier A coding-agent ops (git, terminals) when lab needs them

## Deferred

- Optional: `latest` / omit run-id for approve / choose / reply / show
- Opt-in LangSmith-style LLM transcripts (span-linked payloads; §07 §10)
- Skills phase D (optional writer example)
- Semantic-check S4 / S6 — research only; optional static fitness later
- Coding-agent Tier B (RAG / MCP / LSP) — when needed as a lab benchmark
- Concurrent `par` host IO; MCP client host
- Control-plane repo (HTTP/WS, Postgres metadata, tenants) — **not** in
  hwfl; depends on the library driver + Observer above
- Optional DB-backed run-store backend (same interface; not required yet)
- `lib/` qname elaboration (runtime linking; separate from E11)
- Typed validation of example values vs `TypeExpr`; CLI `--example`

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
