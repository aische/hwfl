# Status

Last updated: 2026-08-07

## Current focus

**Bug-fix pass** — Work [BUG_REPORT.md](BUG_REPORT.md) in the order in
[TASKS.md](TASKS.md) (P0 High → P1 Medium → remaining). Agent substrate
(MCP / git / terminals) waits until that backlog clears.

## North star

hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently

- **H-3 fixed** — JSON numbers decode via `Scientific`; exact integral values
  remain arbitrary-precision `VInt`s, and fractional values outside `Double`'s
  finite range become normal conversion errors rather than crashes
- **H-6 fixed** — Empty application rejects non-`Unit` domains; runtime
  supplies the omitted Unit argument and packs positional/named fields for one
  record parameter. `fs.write` accepts its checked positional form. Residuals
  filed as **M-19** (other named-only host ops, packed→multi-param, alias /
  bare-Unit packing)
- **H-2 fixed** — Synchronous exceptions are contained at three boundaries
  (run loop, host op, LLM provider) via `Hwfl.Exception.trySync`; async
  exceptions and `ExitCode` still propagate. A crash inside a step closes the
  spans it opened, persists the machine as failed (so resume cannot replay an
  already-applied transition) and reports the new non-catchable `InternalErr`
- **H-7 fixed** — Run ids are validated as a single path component before any
  id→path mapping; starting a run is create-only (`createRun`), so reuse can
  no longer merge two runs into one directory; resume / step / approve open
  without creating anything
- **H-1 retracted; H-1a / L-24 fixed** — H-1's dangling-symlink escape was
  not reproducible (`canonicalizePath` resolves dangling links; `copyFile`
  renames). Real bug: parent chains were created before the containment
  check, leaking dirs outside the root. Now `ensureDirUnderRoot` checks
  before each `createDirectory`; `O_NOFOLLOW` writes / `rename` copies;
  `fs.remove` unlinks leaf symlinks (was recursively deleting link targets)
- **Source review** — Full `src/Hwfl/**` read-only review; findings in
  [BUG_REPORT.md](BUG_REPORT.md)
- **Semantic-check layer 0** — `meta.check_project(".")` when
  `project.json` exists; path-based catalog; sandbox via `resolvePath`
- **Host find/grep ignores** — hidden skip; root `.gitignore`/`.ignore`;
  baseline dep/build dirs
- **Coding-agent** — skill-driven exemplar; doer `exec.run`; FrInvoke;
  chat `coding_session`

## Blockers

None.

## Next up

1. P0 High: H-4 float → H-5 `nextPow2`
2. P1 Medium: M-1, M-19, M-5, M-13, M-14, M-2/M-11b, M-7
3. Remaining Medium + selected Lows (see TASKS)
4. Then Tier A agent ops (MCP, git, terminals) / skills variant

## Deferred

- Opt-in Docker `exec.runtime` (spec §05 §3.1) when untrusted spawn bites
- Multi-process run-store locking / **M-16** (until parallel lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Nested ignore files; `fs.find`/`fs.grep` ignore opt-out flag

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
