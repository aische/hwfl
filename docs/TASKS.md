# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now

- [ ] Streaming LLM spans
- [ ] Optional DB-backed run store (hwfi M5 analogue)

## Next

- [ ] Alternate `LlmProvider` (e.g. direct OpenAI/Anthropic SDK) — **low priority**;
      `LlmProvider` interface is shipped; second adapter is swap proof only, not a
      capability blocker

## Later

(empty)

## Done

- [x] Bootstrap: Cabal package, docs pack, Cursor scaffold (2026-07-15)
- [x] Milestones M0–M8 (see [spec/10-acceptance.md](spec/10-acceptance.md))
- [x] Initial multi-file language/runtime specification (2026-07-15)
- [x] M0 syntax skeleton: parser + AST + pretty + markdown loader (2026-07-15)
- [x] M1 pure evaluator: values, prelude builtins, module funs, E01/E02 (2026-07-15)
- [x] M2 type checker: I/O vs main, local inference, schema(T) (2026-07-15)
- [x] M3 effects lattice + `hwfl check` single-module CLI (2026-07-15)
- [x] M4 host runtime + LlmProvider + snapshots + `hwfl run` (2026-07-15)
- [x] M5 `par` + `confirm` + step/resume/approve + machine_json (2026-07-15)
- [x] M6 spans.jsonl + `hwfl show` + redaction (2026-07-15)
- [x] M7 `llm.agent` loop + `tool(f)` typed tools (2026-07-15)
- [x] M8 slim semantic-check dogfood + LOC/file delta vs hwfi (2026-07-15)
- [x] M8 follow-up: valid JSON semantic report in run folder; `json.encode`; `ctx` (2026-07-15)
- [x] Full kont / `machine_json` codec (M5)
- [x] M9 project-wide `hwfl check` (`project.json` + import graph) (2026-07-15)
- [x] Float / `==` polymorphism cleanup (2026-07-15)
- [x] `llm.object` + schema reflection at runtime (E14) (2026-07-15)
- [x] `llm.agent_object` + synthetic `submit` tool (2026-07-15)
- [x] Polymorphic `obs.span` check type (E16) (2026-07-15)
- [x] Add parameter descriptions to builtin agent tools (2026-07-16)
- [x] Allow optional `## schema Typename` sections in module markdown for
      `schema(T)` field descriptions (2026-07-16)
