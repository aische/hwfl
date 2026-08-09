# Status
Last updated: 2026-08-09

## Current focus
**Agent substrate** — MCP / git / persistent terminals (prefer MCP or
workflow modules over new host ops). Agent context L1+L2 (heuristic)
shipped; LLM compact mode still deferred.

## North star
hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently
- **Typed `examples` + `--example`** — `hwfl check` validates example
  values vs frontmatter `TypeExpr` (JSON Schema); `hwfl run --example
  <name>` loads named samples (`--input` overrides). Fixes L-18.
- **Context L1+L2** — `context_window` / wire view + `get_history`;
  `consolidate = heuristic|manual` (omit = off); pins + summary +
  assemble; `"llm"` documented but rejected. Module:
  `Hwfl.Runtime.Context`. Full `agHistory` unchanged in snapshots.
- **coding-agent-chat** — dogfoods L1+L2; lasting `context` across outer
  turns waits on `"llm"`
- **Bug-report pass** — all High (H-1 retracted) and Medium except
  M-3 / M-16 / M-18; selected Lows through L-15 + L-18 — see
  [BUG_REPORT.md](BUG_REPORT.md)

## Blockers
None.

## Next up
1. Tier A agent ops: MCP client, git (read-heavy), persistent terminals
2. Context L2 follow-up: `consolidate = "llm"` + lasting `context`
   seed/return (update host-op / language-reference API docs)
3. Skills coding-agent variant (separate example) when substrate exists
4. Opportunistic Lows; M-3 / M-18 only if they bite

## Deferred
- **`consolidate = "llm"`** — LLM compact backend + lasting agent
  `context` (pins/summary/watermark) seed/return
- **M-3** skill-body prompt trust (when third-party skills matter)
- **M-18** project-hash / prose-edit resume UX (only if comment edits brick resume often)
- **M-16** multi-process run-store locking (until parallel lab processes share a run dir)
- Remaining Lows (L-4, L-9–10, L-12, L-17, L-20–21, L-23, L-25)
- Opt-in Docker `exec.runtime`; semantic-check S4 / S6; skills phase D;
  concurrent `par` host IO; coding-agent Tier B; `latest` / omit run-id;
  `lib/`; nested ignore; find/grep ignore opt-out

## Open naming
Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
