# Idea

A resumable workflow engine whose programs are **typed markdown modules**:
prose (prompts, descriptions) and code share one file, the way PHP mixed
HTML and logic for the web. Inside those modules runs a **small ML-ish
general-purpose language** with first-class LLM, filesystem, parallelism,
human confirmation, and durable resume.

Working name: **pml** (Prose ML). Rename at leisure.

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
   human confirm (policy proven useful in hwfi).
6. **Observability** — span trees + append-only audit events; better
   “what happened / where are we” than a flat event soup.
7. **Static check before run** — project graph, signatures, effects, and
   types fail closed before the first billed token.
8. **Dogfood semantic analysis** — use the language to analyse its own
   projects (prompts, refs, coherence) without inventing a second DSL.

## Non-goals (v0)

- GUI
- Distributed / multi-tenant runtime
- Package registry
- Embedding a full existing language (JS / Python / Lua runtimes)
- User-defined algebraic effect handlers
- Perfect parity with hwfi’s step DSL on day one

## Constraints

- Haskell, GHC2021
- Default LLM: [llm-simple](https://hackage.haskell.org/package/llm-simple)
  behind an internal `LlmProvider` interface so production backends can
  replace it without rewriting workflows
- Security defaults: workspace sandbox, opt-in `exec`, secret redaction

## Relationship to hwfi

hwfi proved: markdown projects, type-checked load, resume frames, `par` +
confirm, tools/skills/trace introspection. It failed as a *general*
language (expression sub-language too weak; logic → micro-tools).

**Reuse ideas and machine shape from hwfi; do not reuse the step DSL as
the computation substrate.** See [hwfi-reference.md](hwfi-reference.md).

## Success intuition

An author (human or agent) can write a non-trivial multi-step agent
pipeline — including parallelism, human gates, and structured LLM JSON —
in a handful of markdown modules, resume after crash mid-LLM-call, and
inspect a span tree of what ran. Porting hwfi’s `semantic-check` should
collapse tens of micro-tools into a small library written *in* pml.
