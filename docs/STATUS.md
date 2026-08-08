# Status
Last updated: 2026-08-08

## Current focus
**Agent substrate** — MCP / git / persistent terminals (prefer MCP or
workflow modules over new host ops). Next context layer: **L2**
consolidate / pins / assemble (L1 window + history slices done).

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **Context L1** — `context_window` / wire view; injected `get_history`;
  optional `max_tool_result_chars` (default 16k when windowed); full
  `agHistory` unchanged in snapshots (`Hwfl.Runtime.Context`)
- **L-15** — Nullary variants encode as `{"tag":…}` (not bare strings);
  Option Some/None interop unchanged
- **L-7** — Empty / duplicate H2/H3 slugs fail at load and `md.sections`
  (ASCII slugify unchanged; no silent last-wins `@slug` binding)
- **L-13** — CLI: `wantsJson` / `--` end-of-options; typed `StaleProjectErr`
  (exit 4 without substring match)
- **L-11** — `skill.tags` rejects non-string list entries (no silent drop)
- **L-8** — Import-cycle report DFS over remaining nodes (no false paths)
- **L-3** — Fail-closed pause parse; validate `snapshot_format`
- **L-22** — `fs.find` / `fs.grep` extension globs ASCII case-insensitive
- **L-1 / L-2** — Idempotent LIFO `closeSpan`; region unwind on abort/catch;
  `failAgent` sole owner of agent_round teardown
- Bug-report: all High (H-1a–H-7; H-1 retracted) and Medium except
  M-3 / M-16 / M-18 — see [BUG_REPORT.md](BUG_REPORT.md)
- Structured tool outcomes (M-17); Option schema decode (M-11(a));
  `&&`/`||` short-circuit; tight qnames vs division

## Blockers
None.

## Next up
1. Tier A agent ops: MCP client, git (read-heavy), persistent terminals
2. **Agent context L2** (consolidate / pins / assemble)
3. Skills coding-agent variant (separate example) when substrate exists
4. Opportunistic Lows; M-3 / M-18 only if they bite

## Deferred
- **M-3** skill-body prompt trust (when third-party skills matter)
- **M-18** project-hash / prose-edit resume UX (only if comment edits brick resume often)
- **M-16** multi-process run-store locking (until parallel lab processes share a run dir)
- Remaining Lows (L-4, L-9–10, L-12, L-17–18, L-20–21, L-23, L-25)
- Opt-in Docker `exec.runtime`; semantic-check S4 / S6; skills phase D;
  concurrent `par` host IO; coding-agent Tier B; `latest` / omit run-id;
  `lib/`; typed `--example`; nested ignore; find/grep ignore opt-out

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
