# Status
Last updated: 2026-08-08

## Current focus
**Bug-fix pass** — Work [BUG_REPORT.md](BUG_REPORT.md) in the order in
[TASKS.md](TASKS.md) (remaining Medium → selected Lows). Agent substrate
(MCP / git / terminals) waits until that backlog clears.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **M-17 fixed** — Structured `ToolOk`/`ToolErr` for tool span status;
  `finish_reason` on LLM close attrs; `FinishLength` fails the agent
- **M-11(a) fixed** — Option fields omitted from schema `required`;
  `null`/absent decode to `None`, present values to `Some`; language
  `Some`/`None` constructors + match
- **M-4 fixed** — `requestToTurns` joins all `RoleSystem` texts into the
  provider system prompt (no silent drop); Host prepend not double-counted
- **M-12 / M-9 / M-10 / M-6 / M-8 / M-7 / M-2 / M-11(b)** — See report

## Blockers
None.

## Next up
1. Remaining Medium: M-3, M-18
2. Selected Lows (L-5 / L-6 / L-14 / L-16 and opportunistic hygiene)
3. Then Tier A agent ops (MCP, git, terminals) / skills variant

## Deferred
- Opt-in Docker `exec.runtime` (spec §05 §3.1) when untrusted spawn bites
- Multi-process run-store locking / **M-16** (until parallel lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Nested ignore files; `fs.find`/`fs.grep` ignore opt-out flag

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
