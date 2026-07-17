# Status

Last updated: 2026-07-17

## Current focus

Skills phase D (optional), then run-store interface.

## Done recently

- **Semantic-check noise fix** — module-tree scan only; `text.is_qname` /
  `normalize_token` / `starts_with` / `trim`; system speech-act + broader
  directives; coding-agent dogfood `ok:true` (~2 findings vs ~35)
- **Semantic-check deepen** — body-bearing `review_gate`; same-run layer 3;
  `loadTypeEnv` elaborates `main` I/O for `schema(T)`
- **Streaming LLM spans**; `--json` CLI; `fs.read_slice` / `fs.remove`;
  try/catch; skills A–C; coding-agent; P0; M0–M9

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
