# Status

Last updated: 2026-07-17

## Current focus

Skills phase D (optional), then run-store interface.

## Done recently

- **Semantic-check deepen** — body-bearing `review_gate` (priority policy);
  same-run optional layer 3 (`mode=pragmatic` + `llm.object`); runtime
  `loadTypeEnv` elaborates `main` I/O so `schema(T)` aliases resolve
- **Streaming LLM spans** — `chatOnChunk` / `StreamDelta`; coalesced
  `llm.delta` events; mock chunks; llm-simple streaming; `--debug` echo
- **`--json` CLI** — machine-readable error envelopes on `check` / `run`
- **`fs.read_slice` / `fs.remove`** — line-range read + sandboxed remove
- **`try` / `catch` runtime** — `FrTry` frame, catchable errors, E10 tests
- LLM span cost; coding-agent + skills A–C; lifecycle tutorial; P0; M0–M9

## Blockers

None.

## Next up

1. Skills phase D (optional) — writer workflow; no hidden `skill.extract`
2. Run-store interface → optional DB; later Servant API; later MCP client
3. Alternate `LlmProvider` — low priority

## Deferred (nice-to-have)

- **`par` concurrent host IO** — M5 pool is cooperative (one branch
  transition at a time; blocking host ops stall the whole driver). Future:
  async at host boundaries without changing `par` language semantics.
  See [spec/06-runtime.md](spec/06-runtime.md) §10.
- **Coding-agent capability (Tier A/B)** — `fs.patch`, git host ops,
  persistent terminals, context pre-pass; then codebase index, LSP bridge,
  rules/hooks skills, auto context assembly, multi-model routing. See
  [TASKS.md](TASKS.md) “Future / nice-to-have”. Prefer MCP over host growth.
  IDE / product shell (Tier C) remains out of scope.
- Split `semantic-pragmatic` / summary packaging / CLI sugar (same-run
  layer 3 is enough for now).

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
