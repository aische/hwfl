# Status
Last updated: 2026-08-08

## Current focus
**Agent substrate** — MCP / git / persistent terminals (prefer MCP or
workflow modules over new host ops). Bug-report High + nearly all Medium
are done; leftover findings are deferred hygiene.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **L-3** — Fail-closed pause parse; validate `snapshot_format`
- **L-22** — `fs.find` / `fs.grep` extension globs ASCII case-insensitive
- **L-1 / L-2** — Idempotent LIFO `closeSpan`; region unwind on abort/catch;
  `failAgent` sole owner of agent_round teardown
- Bug-report: all High (H-1a–H-7; H-1 retracted) and Medium except
  M-3 / M-16 / M-18 — see [BUG_REPORT.md](BUG_REPORT.md)
- Parser/eval footguns: L-5 / L-6 / L-14 / L-16 (+ L-19 / L-24 with Highs)
- Structured tool outcomes (M-17); Option schema decode (M-11(a));
  `&&`/`||` short-circuit; tight qnames vs division

## Blockers
None.

## Next up
1. Tier A agent ops: MCP client, git (read-heavy), persistent terminals
2. Skills coding-agent variant (separate example) when substrate exists
3. Opportunistic Lows from the report; M-3 / M-18 only if they bite

## Deferred
- **M-3** skill-body prompt trust (when third-party skills matter)
- **M-18** project-hash / prose-edit resume UX (only if comment edits brick resume often)
- **M-16** multi-process run-store locking (until parallel lab processes share a run dir)
- Remaining Lows (L-4, L-7–13, L-15, L-17–18, L-20–21, L-23, L-25)
- Opt-in Docker `exec.runtime`; semantic-check S4 / S6; skills phase D;
  concurrent `par` host IO; coding-agent Tier B; `latest` / omit run-id;
  `lib/`; typed `--example`; nested ignore; find/grep ignore opt-out

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
