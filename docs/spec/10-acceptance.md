# 10 — Acceptance criteria & milestones

## 1. Fitness metrics (ongoing)

| Metric | Target intuition |
|--------|------------------|
| Author files for semantic-check-class workflow | ≪ hwfi’s ~70 tools; aim ≤ 15 modules |
| Resume mid-LLM | Exact stack restore; at-most duplicate that call |
| Failed-run comprehension | `pml show --tree` sufficient without reading JSON dumps |
| Provider swap | Second adapter selectable; one test green |

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
- [ ] Check module I/O vs `main`
- [ ] Local inference good enough for examples
- [ ] `schema(T)` for records/lists

### M3 — Effects + `check` CLI
- [ ] Effect lattice enforced
- [ ] `pml check` usable

### M4 — Host + LLM + snapshots
- [ ] Workspace FS ops + sandbox tests
- [ ] `LlmProvider` + llm-simple adapter
- [ ] Snapshots after host transitions
- [ ] `pml run` end-to-end summarise example

### M5 — Concurrency & human
- [ ] `par` with bound + ordered results
- [ ] `confirm` + `approve`
- [ ] Cooperative freeze in `par`
- [ ] `step` / `resume`

### M6 — Observability
- [ ] spans.jsonl + tree show
- [ ] Redaction tests
- [ ] No full-trace rebuild per step

### M7 — Agent
- [ ] `llm.agent` multi-transition loop
- [ ] Typed tools from functions

### M8 — Dogfood
- [ ] Port slim semantic-check (layers 0–2 style) in pml
- [ ] Compare file count / LOC to hwfi example
- [ ] Decision log entry with results

## 3. v0 release gate

All of M0–M7 required; M8 strongly expected before calling the language
“good enough to retire hwfi for new work.”

## 4. Explicit non-acceptance

- Shipping a second step-DSL
- Workflows importing llm-simple types
- Resume based on content-addressed step cache
- Unsandboxed filesystem
