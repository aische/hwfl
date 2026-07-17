# Status

Last updated: 2026-07-17

## Current focus

Skills phase D (optional), then run-store interface.

## Done recently

- **`fs.patch`** — unique multi-hunk atomic edit; agent-tool eligible;
  coding-agent prefers it over replace-all `fs.edit`
- **Semantic-check A+B** — policy gate (`check_internal_conflict` on
  skills / system / rules); within-slice quoted sentence redundancy
  (cap 16); H1-only skills get synthetic slices; gate unique by
  `(slice_id, review_task)`, policy first, cap 8
- **Semantic-check noise fix** — module-tree scan; `text.is_qname` /
  friends; coding-agent dogfood `ok:true`
- **Semantic-check deepen** — body-bearing `review_gate`; same-run
  layer 3; `loadTypeEnv` elaborates `main` I/O for `schema(T)`
- Streaming LLM spans; `--json` CLI; skills A–C; coding-agent; P0; M0–M9

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
- **Coding-agent capability (Tier A/B)** — git host ops, persistent
  terminals, context pre-pass; then codebase index, LSP bridge,
  rules/hooks skills, auto context assembly, multi-model routing. See
  [TASKS.md](TASKS.md) “Future / nice-to-have”. Prefer MCP over host growth.
  IDE / product shell (Tier C) remains out of scope.
- Split `semantic-pragmatic` / summary packaging / CLI sugar (same-run
  layer 3 is enough for now).
- Semantic-check research (roles, obligation graph, prose↔code,
  dynamic) — [semantic-check-plan.md](semantic-check-plan.md).

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
