# Status

Last updated: 2026-07-17

## Current focus

Semantic-check deepen / skills phase D, then run-store interface.

## Done recently

- **Streaming LLM spans** — `chatOnChunk` / `StreamDelta`; coalesced
  `llm.delta` events on open `llm.chat` / `agent_round` spans; mock fake
  chunks; llm-simple `streamTextWithFallbacks`; coalesced `--debug` echo
- **Streaming LLM spans — design locked** (docs): obs side channel; atomic
  host ops; no in-language streams
- **`--json` CLI** — machine-readable error envelopes on `check` / `run`
- **`fs.read_slice` / `fs.remove`** — line-range read + sandboxed remove
- **`try` / `catch` runtime** — `FrTry` frame, catchable errors, E10 tests
- LLM span cost: catalog pricing → `cost_usd`; `--debug` ledger; `hwfl show`
- Coding-agent + skills A–C; lifecycle tutorial; tool-call spans; P0; M0–M9

## Blockers

None.

## Next up

1. Semantic-check deepen (optional LLM layer; packaging)
2. Skills phase D (optional) — writer workflow; no hidden `skill.extract`
3. Run-store interface → optional DB; later Servant API; later MCP client
4. Alternate `LlmProvider` — low priority

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

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
