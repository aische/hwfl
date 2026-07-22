# Status

Last updated: 2026-07-22

## Current focus

**Exemplars** — Credible **skill-driven** coding-agent shipped
(`examples/coding-agent`: chat → FrInvoke coding session → typed plan →
serial do_task/verify; `skill.*` on planner/coder). Next: Tier A agent
ops when the exemplar needs them, or the workflow-driven skills variant.
Control plane: **hwfl-server**.

## North star

hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently

- **FrInvoke sections** — callee `@section` / `schema(T)` surface installed
  on nest (fixes chat→`coding_session` trap `unknown section: @plan-system`)
- **Chat tools** — coding-agent chat exposes only `coding_session`
  (survey stays inside the session)
- **Credible coding-agent** — chat → FrInvoke `workflows/coding` → plan →
  serial do_task/verify; FrInvoke callee fun table
- **#5 Agent submit / tool identity** — schema validation + tool-name
  uniquify
- **#4 Checker holes** — empty `match`; `confirm` / `choice` shape
- **#3 Crash-safe store + run IDs**
- **#2 `meta.invoke` sandbox** / **#1 Nested snapshot persist**

## Blockers

None.

## Next up

1. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
2. Workflow-driven skills coding-agent variant (separate example project)
3. Opt-in LangSmith-style LLM transcripts
4. Medium/Low `issues.md` items when they bite an exemplar

## Deferred

- Opt-in Docker `exec.runtime` (spec §05 §3.1) when untrusted spawn bites
- Multi-process run-store locking (until parallel external lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Structured exhausted return with `history`; TM δ skills (multiply, etc.)
- Most Medium/Low items in `issues.md` until they bite an exemplar
- `meta.check_project` still joins paths with raw `</>` (same class of
  bug as #2; not yet sandboxed)

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
