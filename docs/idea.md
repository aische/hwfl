# Idea

A resumable workflow engine whose programs are **typed markdown modules**:
prose (prompts, descriptions) and code share one file, the way PHP mixed
HTML and logic for the web. Inside those modules runs a **small ML-ish
general-purpose language** with first-class LLM, filesystem, parallelism,
human confirmation, and durable resume.

Working name: **hwfl** (originally plm, Prose ML).

## North star

**hwfl is the durable workflow runtime (Haskell library + CLI).** It powers
a **workflow research lab**: author → check → run → inspect → **compare
orchestration variants** (multiple markdown programs on the same fixtures —
cheap because the experiment *is* the workflow, not a second host app) →
optionally mutate / evolve candidates. Coding-agent tasks and
semantic-check are hard benchmarks — not the product itself.

A **remote control plane** (separate repo) depends on hwfl as a library:
Postgres for experiment / run metadata, materialized project + workspace
sandboxes to execute, HTTP + WebSocket/SSE mapping the existing
check / run / step / resume / approve / show machine — not a remote
terminal. Multi-tenant auth, queuing, and chat UX stay in that app.

## Problem

Agentic systems today split work awkwardly:

1. **Orchestration** lives in a general-purpose host language (TypeScript,
   Python, …) with a lot of HTTP, schema, retry, and async noise.
2. **Prompts and descriptions** are string constants buried in that code —
   hostile to editing, review, and agent self-modification.
3. **Custom “workflow DSLs”** (including hwfi’s step language) are pleasant
   for linear tool graphs but collapse under real computation: every missing
   expression form becomes another builtin or micro-file.

We want language-level ergonomics **and** document-shaped authoring.

## Goals

1. **Document modules** — workflows / tools / libraries are markdown files
   with YAML frontmatter (typed interface) and fenced code blocks (logic).
   Prose sections are first-class data for prompts.
2. **Minimal ML core** — `let`, functions, `match`, records, lists,
   string interpolation; no objects, no huge standard library in the host.
3. **LLM as host effect** — `llm.chat`, `llm.object`, `llm.agent` with
   schemas derived from types; provider backends swappable.
4. **Durable execution** — stack/frame interpreter; checkpoints at host-op
   boundaries; crash/abort resume; `--step` / confirm gates.
5. **Structured concurrency** — bounded `par` with cooperative freeze on
   human confirm (policy proven useful in hwfi). The pool is cooperative;
   branches do not overlap blocking host IO.
6. **Observability** — span trees + append-only audit events; better
   “what happened / where are we” than a flat event soup.
7. **Static check before run** — project graph, signatures, effects, and
   types fail closed before the first billed token.
8. **Callable as a library** — one driver façade (check / run / step /
   resume / approve / show + run-store queries) shared by the CLI and HTTP
   frontends; FS run-store today.
9. **Comparative + genetic workflows** — first-class: ship N **separate
   example projects** (distinct trees; accept duplication until `lib/`)
   and compare on shared fixtures (spans / cost / outcome). Not one
   workflow with a mode switch. Separately: materialize candidate
   projects (and workspaces), invoke nested runs, score, iterate /
   evolve; evolution logic prefers hwfl modules over host growth.
   Comparison without mutation is already research — evolve is not
   required to justify multiple exemplars.
10. **Dogfood semantic analysis** — use the language to analyse its own
    projects (prompts, refs, coherence) without inventing a second DSL.
    Research track; not on the critical path.

## Non-goals (this repo)

- GUI / IDE product shell
- Distributed / multi-tenant runtime, auth, job queues, chat UX
- Servant (or any HTTP API) **in this repository** — belongs in a separate
  control-plane app that depends on the hwfl library
- Package registry
- Embedding a full existing language (JS / Python / Lua runtimes)
- User-defined algebraic effect handlers
- Reintroducing hwfi’s step DSL as the computation substrate
- Cursor-class RAG / LSP / embeddings until a measured coding-agent gap

## Constraints

- Haskell, GHC2021
- Default LLM: [llm-simple](https://hackage.haskell.org/package/llm-simple)
  behind an internal `LlmProvider` interface so production backends can
  replace it without rewriting workflows
- Security defaults: workspace sandbox, opt-in `exec`, secret redaction
- Prefer MCP / in-language modules over growing the host-op set
- **Project** (workflow modules / genome) ≠ **workspace** (sandbox data +
  `.hwfl/runs`); lab and control plane materialize both as directories

## Relationship to hwfi

hwfi proved: markdown projects, type-checked load, resume frames, `par` +
confirm, tools/skills/trace introspection. It failed as a _general_
language (expression sub-language too weak; logic → micro-tools).

**Reuse ideas and machine shape from hwfi; do not reuse the step DSL as
the computation substrate.** Skills (progressive disclosure) ship as
`skills/` + `skill.discover` / `skill.load`.

## Success intuition

An author (human or agent) can write a non-trivial multi-step agent
pipeline — including parallelism, human gates, and structured LLM JSON —
in a handful of markdown modules, resume after crash mid-LLM-call, and
inspect a span tree of what ran. Proof point: hwfi’s `semantic-check`
(~74 tool files) collapsed to **one** hwfl module
(`examples/semantic-check`) with the same layered review policy — the GP
language replaces micro-tool fan-out.

**Lab intuition:** a parent workflow (or thin driver) can spawn N candidate
projects in temp dirs, check/run each against a shared task fixture,
read spans + cost + outcome, and select/mutate for the next generation —
locally via the library/CLI; on a server via the separate control plane.
