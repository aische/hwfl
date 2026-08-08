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
- **M-12 fixed** — Par treats `PauseAwaitingAgent` / crash-recovery as not
  runnable; agent budget exhaustion freezes the pool like human gates and
  surfaces `awaiting_extend` so `hwfl extend` can bump the branch budget
- **M-9 / M-10 / M-6** — Duplicate YAML keys, let-alias residuals, `exec.run`
  stream caps + process-group timeout
- **M-8 / M-7 / M-15 / M-2 / M-11(b) / M-14** — Resource ceilings, contained
  module/catalog I/O, secret re-wrap + redaction, sentence split; see report
- **M-13 / M-5 / M-19 / M-1 / H-cluster** — See [BUG_REPORT.md](BUG_REPORT.md);
  P0 High and several Mediums closed

## Blockers
None.

## Next up
1. Remaining Medium: M-4, M-11(a), M-3, M-17, M-18
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
