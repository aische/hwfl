# Status

Last updated: 2026-07-17

## Current focus

Streaming LLM spans (progressive token / partial events), then
semantic-check deepen / skills phase D.

## Done recently

- **`--json` CLI** — machine-readable error envelopes on `check` / `run`
  (`status`, `exit_code`, `category`, `kind`, `message`; parse diagnostics)
- **`fs.read_slice` / `fs.remove`** — line-range read (1-based inclusive) and
  sandboxed file/dir removal; agent-tool eligible
- **`try` / `catch` runtime** — `FrTry` frame, catchable host/provider/sandbox
  errors, type checker, snapshot resume, E10 tests
- LLM span cost: catalog pricing → `cost_usd` on spans; running `$` ledger
  on `--debug`; per-span + run total on `hwfl show` tree
- Coding-agent + skills: stack instruction playbooks (python / react /
  haskell / rust); discover/load in the agent toolbox
- Skills A–C: catalog, `skill.*` host ops, mid-loop load + budgets
- Lifecycle tutorial; tool-call spans + `--debug`
- P0 host gaps; M0–M9 complete

## Blockers

None.

## Next up

1. Streaming LLM spans (progressive token/partial events)
2. Semantic-check deepen (optional LLM layer; packaging)
3. Skills phase D (optional) — writer workflow; no hidden `skill.extract`
4. Run-store interface → optional DB; later Servant API; later MCP client
5. Alternate `LlmProvider` — low priority

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
