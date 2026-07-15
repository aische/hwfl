# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now

- [ ] Full `pml check` project.json + import graph

## Later

- [x] Full kont / `machine_json` codec (M5)
- [ ] Alternate `LlmProvider` (e.g. direct OpenAI/Anthropic SDK) as proof of swap
- [ ] Streaming LLM spans
- [ ] Optional DB-backed run store (hwfi M5 analogue)
- [ ] Polymorphic `obs.span` check type (v0 approximates Unit→Unit)

## Done

- [x] Bootstrap: Cabal package, docs pack, Cursor scaffold (2026-07-15)
- [x] Milestones M0–M8 (see [spec/10-acceptance.md](spec/10-acceptance.md))
- [x] Initial multi-file language/runtime specification (2026-07-15)
- [x] M0 syntax skeleton: parser + AST + pretty + markdown loader (2026-07-15)
- [x] M1 pure evaluator: values, prelude builtins, module funs, E01/E02 (2026-07-15)
- [x] M2 type checker: I/O vs main, local inference, schema(T) (2026-07-15)
- [x] M3 effects lattice + `pml check` single-module CLI (2026-07-15)
- [x] M4 host runtime + LlmProvider + snapshots + `pml run` (2026-07-15)
- [x] M5 `par` + `confirm` + step/resume/approve + machine_json (2026-07-15)
- [x] M6 spans.jsonl + `pml show` + redaction (2026-07-15)
- [x] M7 `llm.agent` loop + `tool(f)` typed tools (2026-07-15)
- [x] M8 slim semantic-check dogfood + LOC/file delta vs hwfi (2026-07-15)
