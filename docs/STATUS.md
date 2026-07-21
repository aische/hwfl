# Status

Last updated: 2026-07-21

## Current focus

**Runtime integrity (source-review High #5)** — “checked ≈ safe”
before leaning harder on nested invoke / E11. Findings live in repo-root
`issues.md` (do not treat as spec). Control plane remains **hwfl-server**.

## North star

hwfl = durable workflow **runtime library**. Toward a **workflow research
lab** (compare / mutate / re-run candidates). Coding-agent and
semantic-check are benchmarks / research, not the product. See
[idea.md](idea.md).

## Done recently

- **#4 Checker holes** — empty `match` rejected in check mode;
  `confirm` / `choice` / `human.confirm` / `human.choice` check record
  shape (`title` required, `detail` optional, `options` for choice);
  runtime rejects missing required fields instead of coercing to `""`
- **#3 Crash-safe store + run IDs** — `meta.json` / `snapshot.json` via
  temp + rename; `newRunId` adds 64-bit entropy (locking still deferred)
- **#2 `meta.invoke` sandbox** — `project` / `workspace` via `resolvePath`
  + canonicalize (same containment as `fs.*`); abs / `../` / symlink
  parent rejected
- **#1 Nested snapshot persist** — `rcNestDepth` suppresses branch
  writes; agent tools / `FrInvoke` / `par` persist only the outer machine
- Turing-machine exemplar; zero-arg funs; soft-land `max_rounds`;
  `obs.log` non-snapshotting; evolve-agent v2; E23 / E11 / lab spine

## Blockers

None.

## Next up

1. Fix High #5 (agent submit schema validation + uniquify tool names)
2. Credible coding-agent exemplar: tools that call workflows (E11)
3. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
4. Opt-in LangSmith-style LLM transcripts

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
