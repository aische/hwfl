# Status

Last updated: 2026-07-17

## Current focus

Implement streaming LLM spans (design locked — progressive events only),
then semantic-check deepen / skills phase D.

## Done recently

- **Streaming LLM spans — design locked** (docs): obs side channel on
  open LLM / `agent_round` spans; atomic host ops; no in-language streams
- **`--json` CLI** — machine-readable error envelopes on `check` / `run`
  (`status`, `exit_code`, `category`, `kind`, `message`; parse diagnostics)
- **`fs.read_slice` / `fs.remove`** — line-range read (1-based inclusive) and
  sandboxed file/dir removal; agent-tool eligible
- **`try` / `catch` runtime** — `FrTry` frame, catchable host/provider/sandbox
  errors, type checker, snapshot resume, E10 tests
- LLM span cost: catalog pricing → `cost_usd` on spans; running `$` ledger
  on `--debug`; per-span + run total on `hwfl show` tree
- Coding-agent + skills: stack instruction playbooks; skills A–C
- Lifecycle tutorial; tool-call spans + `--debug`; P0 host gaps; M0–M9

## Blockers

None.

## Next up

1. Implement streaming LLM spans ([07 §9](spec/07-observability.md),
   [08 §2.2](spec/08-llm-provider.md))
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
