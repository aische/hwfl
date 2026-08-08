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
  sentence after completed ones; regression tests cover both sentence forms,
  one fragment, and whitespace-only input
- **M-13 fixed** — Ordinary evaluator failures persist their failed root
  machine before finalization; `meta.json` and `snapshot.json` report the same
  terminal status, and resume cannot replay the failed step
- **M-5 fixed** — Shared filesystem traversal refuses directory-symlink
  descent; every listed directory has canonical containment and cycle checks
- **M-19 fixed** — Record-domain host calls normalize packed records and accept
  checked positionals; multi-parameter functions unpack lone records; runtime
  parameters resolve aliases and bare singleton parameters are Unit thunks
- **M-1 fixed** — `llm.object` validates provider responses with
  `validateAgainstSchema` before `jsonToValue`, so malformed or mistyped model
  output is a normal `HostErr` rather than a checker-soundness violation
- **H-5 + L-19 / H-3 / H-4 / H-6 / H-2 / H-7 / H-1a** — See prior entries /
  [BUG_REPORT.md](BUG_REPORT.md); P0 High cluster closed

## Blockers
None.

## Next up
1. P2: M-6 (exec.run resources), then M-10 / M-12 / M-9
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
