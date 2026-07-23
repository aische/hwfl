# Status

Last updated: 2026-07-23

## Current focus

**Exemplars** — Credible **skill-driven** coding-agent shipped
(`examples/coding-agent`). Next: Tier A agent ops when the exemplar
needs them, or the workflow-driven skills variant. Control plane:
**hwfl-server**.

## North star

hwfl = durable workflow **runtime library** (language + interpreter).
Coding-agent and semantic-check are benchmarks / dogfood, not the
product. Broader lab framing in [idea.md](idea.md).

## Done recently

- **Semantic-check layer 0** — `meta.check_project(".")` when
  `project.json` exists (import-graph aware); per-file
  `meta.check_module` fallback for loose trees; path-based catalog
- **`meta.check_project` sandbox** — paths via `resolvePath` (same class
  as `meta.invoke`); fixes `"."` → `workspace/.` discovery breakage
- **Docs hygiene** — root README aligned (framing, flag order, model
  input, doc index); drop stale E11 “planned”, missing `issues.md`
  refs, and milestone tags in author/spec surfaces
- **Host find/grep ignores** — hidden skip; root `.gitignore`/`.ignore`
  without requiring `.git`; baseline dep/build dirs when absent
- **gather_context** — stack-scoped finds; lockfile drop + caps
- **Resume exec policy** — ask/reply reloads `exec.allow` from source
- **Coding-agent** — doer `exec.run`; FrInvoke sections; chat
  `coding_session`

## Blockers

None.

## Next up

1. Tier A agent ops (MCP, git, terminals) when the exemplar needs them
2. Workflow-driven skills coding-agent variant (separate example project)
3. Opt-in LangSmith-style LLM transcripts
4. Medium/Low source-review items when they bite an exemplar

## Deferred

- Opt-in Docker `exec.runtime` (spec §05 §3.1) when untrusted spawn bites
- Multi-process run-store locking (until parallel external lab processes)
- Semantic-check S4 / S6; skills phase D; concurrent `par` host IO
- Coding-agent Tier B; `latest` / omit run-id; `lib/`; typed `--example`
- Structured exhausted return with `history`; TM δ skills (multiply, etc.)
- Most Medium/Low source-review items until they bite an exemplar
- Nested ignore files; `fs.find`/`fs.grep` ignore opt-out flag

## Open naming

Working title **hwfl** / CLI `hwfl` / fence `hwfl` is provisional.
