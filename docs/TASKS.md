# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now — bootstrap (after greenfield repo)

- [x] Create Cabal/Haskell package (GHC2021)
- [x] Wire `llm-simple` as default provider behind `LlmProvider` (M4)
- [x] **M0** — AST + parser + pretty for kernel (no host ops yet)
- [x] **M0b** — Markdown module loader (frontmatter + fence extraction)
- [x] Move this docs pack to `docs/`; install Cursor scaffold

## Next — milestones (see [spec/10-acceptance.md](spec/10-acceptance.md))

- [x] **M1** — Pure evaluator (CEK / frames) + unit tests
- [x] **M2** — Type checker (signatures + local inference)
- [x] **M3** — Effects lattice + `check` CLI
- [x] **M4** — Host ops: fs + llm (via provider) + snapshots
- [x] **M5** — `par` + `confirm` + resume / `--step`
- [x] **M6** — Span observability + `show`
- [x] **M7** — Agent loop (`llm.agent`) + tool functions
- [x] **M8** — Dogfood: port a slim semantic-check in pml

## Later

- [ ] Full `pml check` project.json + import graph (M3 shipped single-module)
- [x] Full kont / `machine_json` codec (M5)
- [ ] Alternate `LlmProvider` (e.g. direct OpenAI/Anthropic SDK) as proof of swap
- [ ] Streaming LLM spans
- [ ] Optional DB-backed run store (hwfi M5 analogue)
- [ ] Polymorphic `obs.span` check type (v0 approximates Unit→Unit)

## Done

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
