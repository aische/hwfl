# Status

Last updated: 2026-07-17

## Current focus

Skills phase D (optional), then run-store interface.

## Done recently

- **Semantic-check S1** — illocutionary role typing on gated slices
  (`role` + quoted mismatches; Policy/Example felicity; `category: role`)
- **Semantic-check S2** — obligation graph + crunch-budget fix (≤12 graph
  rows; host pure crunch 500k; chatty-extract regression)
- **`fs.patch`** — unique multi-hunk atomic edit; agent-tool eligible;
  coding-agent prefers it over replace-all `fs.edit`
- **Semantic-check A+B** — policy gate (`check_internal_conflict`);
  within-slice quoted redundancy; H1-only synthetic slices; gate cap 8
- Streaming LLM spans; `--json` CLI; skills A–C; coding-agent; P0; M0–M9

## Blockers

None.

## Next up

1. Skills phase D (optional) — writer workflow; no hidden `skill.extract`
2. Run-store interface → optional DB; later Servant API; later MCP client
3. Semantic-check S5 (prose↔code contracts) when resumed — see
   [semantic-check-plan.md](semantic-check-plan.md)

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
- Semantic-check S3–S6 — [semantic-check-plan.md](semantic-check-plan.md).

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
