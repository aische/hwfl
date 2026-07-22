# Status

Last updated: 2026-07-22

## Current focus

**Exemplars** — High #1–#5 runtime integrity landed. Next: credible
**skill-driven** coding-agent (chat → FrInvoke coding session → typed
plan → serial task/verify; `skill.*` on planner/coder). Spec in
[TASKS.md](TASKS.md). Findings in `issues.md` (not spec). Control plane:
**hwfl-server**.

## North star

hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently

- **#5 Agent submit / tool identity** — `validateAgainstSchema` for
  types / nested shape / `additionalProperties` / anyOf/oneOf/enum;
  `uniquifyToolNames` before provider ads (reserves synthetic `submit`)
- **#4 Checker holes** — empty `match`; `confirm` / `choice` record
  shape; runtime rejects missing required fields (no `""` coerce)
- **#3 Crash-safe store + run IDs** — temp + rename; entropy in `newRunId`
- **#2 `meta.invoke` sandbox** — same containment as `fs.*`
- **#1 Nested snapshot persist** — outer-only writes via `rcNestDepth`

## Blockers

None.

## Next up

1. Credible skill-driven coding-agent exemplar — see TASKS
2. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
3. Opt-in LangSmith-style LLM transcripts
4. Medium/Low `issues.md` items when they bite an exemplar

## Deferred

- Workflow-driven skills coding-agent variant (separate example project)
- Multi-process run-store locking (until parallel external lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Structured exhausted return with `history`; TM δ skills (multiply, etc.)
- Most Medium/Low items in `issues.md` until they bite an exemplar
- `meta.check_project` still joins paths with raw `</>` (same class of
  bug as #2; not yet sandboxed)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
