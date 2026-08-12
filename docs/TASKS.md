# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

Findings live in [BUG_REPORT.md](BUG_REPORT.md) (IDs H-/M-/L-). Mark done
here and in the report when fixed; do not re-litigate severity in this file.

## Now — polish and low-hanging fixes

Three remaining improvements identified in review (2026-08-12):

- [ ] **L-20: ignore negation rules beat hidden-segment default** — run the
      ignore rule set first in `Runtime/Ignore.hs`; apply the implicit hidden
      (`.`-prefixed) default only when no rule matches, so `!.env` can actually
      un-ignore `.env`
- [ ] **L-26: fail closed in `confirmOf`/`choiceOf`/`askOf` promotion** — return
      `InternalErr "…: machine shape mismatch"` instead of synthesizing an empty
      request when `mCurrent` doesn't match the expected shape in
      `Runtime/Eval.hs`

## Language + interpreter (ongoing policy)

Prefer MCP clients and in-language modules (`hwfl/*` stdlib, project
`lib/`) over growing the host-op set.

- [x] **Polymorphism** — value / let-polymorphism for user and stdlib
      `fun`s (`List<a>`, `(a) -> b`, …) in check (and eval/snapshots as
      needed). Effect polymorphism stays deferred
      ([spec/03-types.md](spec/03-types.md), [stdlib.md](stdlib.md))
- [x] **Ship stdlib** — pack under repo `stdlib/` (qnames `hwfl/list`,
      `hwfl/string`, `hwfl/option`, …); loader resolves pack root from
      `HWFL_STDLIB` or a sensible default; use from examples
- [x] **Factor large examples** — split oversized mains
      (`real-story-writer`, `semantic-check`) into project `lib/` /
      `types/main` (+ `VLibFun`, imported type aliases)
- [x] **Short hello path** — `hwfl init` scaffold; keep
      [tutorial.md](tutorial.md) focused on check → run (mock) → resume →
      show (shell completions optional)
- [ ] **Host ops** — add new host categories only when the language cannot
      express the need; otherwise MCP or stdlib / `lib/`

## Next — examples and polish

- [ ] Git (read-heavy) via MCP (or host if MCP is inadequate)
- [ ] Persistent terminals via MCP vs one-shot `exec.run`
- [ ] Optional: real-story-writer `world_*` via `mcp.tools` (bind /
      filter commit)
- [ ] Omit / `latest` run-id for approve / choose / reply / show
- [ ] Opt-in LangSmith-style LLM transcripts
      ([07-observability.md](spec/07-observability.md) §10)
- [ ] Concurrent host transitions in `par`
- [ ] Workflow-driven skills coding-agent variant; semantic-check S4/S6;
      skills phase D; lab fitness `cost_micros`

## Deferred bugs (fix only if they bite)

- [ ] **M-3** — Skill-body prompt trust boundary (when third-party skills)
- [ ] **M-16** — Multi-process run-store locking (when parallel processes
      share a run dir)
- [ ] **Remaining Lows** — L-4, L-9–10, L-12, L-23, L-25 (fsync, CLI,
      ignore/glob, stream append atomicity, section parse O(n²))

## Low priority

- [ ] `consolidate = "llm"` — Context L2 LLM summarizer + lasting
      `context` seed/return (pins/summary/watermark); update host-op /
      language-reference signatures. Design notes:
      [log/2026-08.md](log/2026-08.md) (2026-08-08 — agent context layers /
      coding-agent-chat lasting context)
- [ ] Opt-in `exec.runtime` = `host` \| `docker` behind `exec.run`
      (spec [05-host-ops.md](spec/05-host-ops.md) §3.1)
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] Shell completions (with or after `hwfl init`)

## Future / nice-to-have

Delay until a concrete gap shows up in example programs.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope

IDE surface, inline diff UX, browser / multimodal, multi-tenant control
plane / Postgres — separate applications. This repository is the language
and interpreter. See [idea.md](idea.md).

### Super low priority

- [ ] **hwfl as MCP server** — expose check / run / approve over MCP for
      Cursor-like hosts. Distinct from the **MCP client**
      ([spec/13-mcp.md](spec/13-mcp.md)).

## Done

Short hello path (`hwfl init` + tutorial), factored `semantic-check` /
`real-story-writer` into `lib/` + `types/main`, shipped `hwfl/*` stdlib
pack + loader, MCP client (stdio) + story-writer / real-story-writer
examples, Context L1+L2 (heuristic), bug-fix High + Medium (except
      deferred M-3 / M-16), **H-8** / **M-18** / **M-20** / **M-21**, selected Lows
through L-18 (including L-17), **value / let polymorphism**, and typed `--example`
archived in
[log/archive/tasks-2026-08.md](log/archive/tasks-2026-08.md).
Earlier milestones in
[log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md).
