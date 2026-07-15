# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now — bootstrap (after greenfield repo)

- [ ] Create Cabal/Haskell package (GHC2021); wire `llm-simple` as default
      provider behind `LlmProvider`
- [ ] **M0** — AST + parser + pretty for kernel (no host ops yet)
- [ ] **M0b** — Markdown module loader (frontmatter + fence extraction)
- [ ] Move this docs pack to `docs/`; install Cursor scaffold

## Next — milestones (see [spec/10-acceptance.md](spec/10-acceptance.md))

- [ ] **M1** — Pure evaluator (CEK / frames) + unit tests
- [ ] **M2** — Type checker (signatures + local inference)
- [ ] **M3** — Effects lattice + `check` CLI
- [ ] **M4** — Host ops: fs + llm (via provider) + snapshots
- [ ] **M5** — `par` + `confirm` + resume / `--step`
- [ ] **M6** — Span observability + `show`
- [ ] **M7** — Agent loop (`llm.agent`) + tool functions
- [ ] **M8** — Dogfood: port a slim semantic-check in pml

## Later

- [ ] Alternate `LlmProvider` (e.g. direct OpenAI/Anthropic SDK) as proof of swap
- [ ] Streaming LLM spans
- [ ] Optional DB-backed run store (hwfi M5 analogue)

## Done

- [x] Initial multi-file language/runtime specification (2026-07-15)
