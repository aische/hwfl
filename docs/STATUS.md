# Status
Last updated: 2026-08-08

## Current focus
**Bug-fix pass** — Work [BUG_REPORT.md](BUG_REPORT.md) in the order in
[TASKS.md](TASKS.md) (P0 High → P1 Medium → remaining). Agent substrate
(MCP / git / terminals) waits until that backlog clears.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **M-6 fixed** — `exec.run` stream-caps output while reading; timeout kills
  the process group (SIGTERM then SIGKILL) and returns partial capture;
  `timeout_ms` / `max_output_bytes` rejected when invalid at project load and
  at run
- **M-8 fixed** — Resource ceilings on untrusted input: YAML aliases forbidden
  with nesting/node caps; parse depth bounded; linear digit literals; pure-eval
  fuel and CEK frame depth; memoized type-alias expansion
- **M-7 + M-15 fixed** — Module reads use explicit UTF-8 decoding and report
  stable diagnostics; project / discovery / pricing-catalog I/O is contained,
  and an existing malformed catalog is a surfaced configuration error, never
  silent zero pricing.
- **M-2 + M-11(b) fixed** — `Secret` schema annotations survive internally and
  restore `VSecret` after structured model decoding; providers receive standard
  schemas. Events and debug stderr redact sensitive keys, embedded JSON, and
  common credential text before persistence or display.
- **M-14 fixed** — `text.split_sentences` retains an unterminated final
  sentence after completed ones; regression coverage for both sentence forms
- **M-13 / M-5 / M-19 / M-1 / H-cluster** — See [BUG_REPORT.md](BUG_REPORT.md);
  P0 High and several Mediums closed

## Blockers
None.

## Next up
1. P2: M-10 (effect residuals via let-aliases), M-12 (par agent pause), M-9
2. Remaining Medium + selected Lows (see TASKS)
3. Then Tier A agent ops (MCP, git, terminals) / skills variant

## Deferred
- Opt-in Docker `exec.runtime` (spec §05 §3.1) when untrusted spawn bites
- Multi-process run-store locking / **M-16** (until parallel lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Nested ignore files; `fs.find`/`fs.grep` ignore opt-out flag

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
