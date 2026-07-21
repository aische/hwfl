# Status

Last updated: 2026-07-21

## Current focus

**Lab loop + exemplars** — High #1–#5 runtime integrity landed; next lean
into coding-agent tools that call workflows (E11). Findings live in
repo-root `issues.md` (do not treat as spec). Control plane remains
**hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

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

1. Credible coding-agent exemplar: tools that call workflows (E11)
2. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
3. Opt-in LangSmith-style LLM transcripts
4. Medium/Low `issues.md` items when they bite an exemplar

## Deferred

- Multi-process run-store locking (until parallel external lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Structured exhausted return with `history`; TM δ skills (multiply, etc.)
- Most Medium/Low items in `issues.md` until they bite an exemplar
- `meta.check_project` still joins paths with raw `</>` (same class of
  bug as #2; not yet sandboxed)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
