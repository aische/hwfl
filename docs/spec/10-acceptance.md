# 10 — Acceptance criteria & milestones

## 1. Fitness metrics (ongoing)

| Metric | Target intuition |
|--------|------------------|
| Author files for semantic-check-class workflow | ≪ hwfi’s ~70 tools; aim ≤ 15 modules |
| Resume mid-LLM | Exact stack restore; at-most duplicate that call |
| Failed-run comprehension | `pml show --tree` sufficient without reading JSON dumps |
| Provider swap | Second adapter selectable; one test green — **low priority**; `LlmProvider` record already ships |

## 2. Milestones

### M0 — Syntax skeleton
- [x] Parser + AST + pretty for kernel
- [x] Markdown loader (frontmatter, sections, fence)
- [x] Golden parse tests

### M1 — Pure evaluator
- [x] CEK/frames for pure subset
- [x] Lists/records/match/functions
- [x] Unit tests from example suite § pure

### M2 — Types
- [x] Check module I/O vs `main`
- [x] Local inference good enough for examples
- [x] `schema(T)` for records/lists

### M3 — Effects + `check` CLI
- [x] Effect lattice enforced
- [x] `pml check` usable

### M4 — Host + LLM + snapshots
- [x] Workspace FS ops + sandbox tests
- [x] `LlmProvider` + llm-simple adapter
- [x] Snapshots after host transitions
- [x] `pml run` end-to-end summarise example

### M5 — Concurrency & human
- [x] `par` with bound + ordered results
- [x] `confirm` + `approve`
- [x] Cooperative freeze in `par`
- [x] `step` / `resume`

### M6 — Observability
- [x] spans.jsonl + tree show
- [x] Redaction tests
- [x] No full-trace rebuild per step

### M7 — Agent
- [x] `llm.agent` multi-transition loop
- [x] Typed tools from functions

### M8 — Dogfood
- [x] Port slim semantic-check (layers 0–2 style) in pml
- [x] Compare file count / LOC to hwfi example
- [x] Decision log entry with results

### Post-M8 (not yet milestone-numbered)

- [ ] **M9 (proposed)** — project-wide `pml check`: `project.json` + import graph
- [ ] Float / `==` polymorphism cleanup
- [ ] `llm.object` runtime (E14); `llm.agent-object` + submit tool
- [ ] Alternate `LlmProvider` adapter — low priority swap proof

## 3. v0 release gate

**Milestones M0–M8 are complete** (2026-07-15). Before treating pml as the
default substrate for all new agent work vs hwfi:

- **Required next:** project-wide **`pml check`** (import graph, multi-module)
- **Ongoing fitness:** resume, span comprehension, semantic-check-class ergonomics
- **Deferred / low priority:** second LLM provider adapter (interface already exists)

## 4. Explicit non-acceptance

- Shipping a second step-DSL
- Workflows importing llm-simple types
- Resume based on content-addressed step cache
- Unsandboxed filesystem
