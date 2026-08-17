# Idea

A small **programming language** whose programs are **typed markdown
modules**: prose (prompts, descriptions) and code share one file, the way
PHP mixed HTML and logic for the web. Inside those modules runs an **ML-ish
kernel** with first-class LLM calls, filesystem, process, parallelism,
human confirmation, and durable resume.

Working name: **hwfl** (originally plm, Prose ML).

## North star

**hwfl is a language + durable interpreter** (Haskell library + CLI).

Authors write programs as markdown modules; the interpreter checks them,
runs them with LLM and other host effects, and resumes after crash or
human pause. The same driver façade is available as a library for other
frontends (for example a remote control plane in a separate repository).

Example projects under `examples/` — coding agents, story pipelines,
compare/evolve loops, semantic-check, and so on — exercise the language
across different program shapes and guide which builtins and libraries
to add next.

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
   resume / approve / show + run-store queries) shared by the CLI and any
   external frontend; FS run-store today.
9. **Stdlib in-language** — prefer shipped `hwfl/…` modules, project
   `lib/`, and MCP clients over growing the Haskell host-op set. Value
   polymorphism unblocks a real stdlib; new host ops only when the
   language cannot express the need ([architecture.md](architecture.md)).
10. **Teachable surface** — a short path from install → tiny program →
    check / run / resume / show ([manual/tutorial.md](../manual/tutorial.md)).

## Non-goals (this repo)

- GUI / IDE product shell
- Distributed / multi-tenant runtime, auth, job queues, chat UX
- Servant (or any HTTP API) **in this repository** — belongs in a separate
  control-plane app that depends on the hwfl library
- Package registry
- Embedding a full existing language (JS / Python / Lua runtimes)
- User-defined algebraic effect handlers
- Reintroducing hwfi’s step DSL as the computation substrate
- Cursor-class RAG / LSP / embeddings until a measured language gap

## Constraints

- Haskell, GHC2021
- Default LLM: [llm-simple](https://hackage.haskell.org/package/llm-simple)
  behind an internal `LlmProvider` interface so production backends can
  replace it without rewriting workflows
- Security defaults: workspace sandbox, opt-in `exec`, secret redaction
- Prefer MCP **client** / in-language modules (`hwfl/…`, project `lib/`)
  over growing the host-op set (stdio servers: KB, web search, … —
  [spec/13-mcp.md](spec/13-mcp.md))
- **Project** (modules) ≠ **workspace** (sandbox data + `.hwfl/runs`)

## Relationship to hwfi

hwfi proved: markdown projects, type-checked load, resume frames, `par` +
confirm, tools/skills/trace introspection. It failed as a _general_
language (expression sub-language too weak; logic → micro-tools).

**Reuse ideas and machine shape from hwfi; do not reuse the step DSL as
the computation substrate.** Skills (progressive disclosure) ship as
`skills/` + `skill.discover` / `skill.load`.

## Success intuition

An author can write a non-trivial program — LLM structured output,
parallelism, human gates, tools, resume mid-call — in a handful of
markdown modules, and inspect a span tree of what ran. Example programs
(coding-agent, story pipelines, local compare/evolve, semantic-check vs
hwfi’s micro-tool fan-out) show that the language carries those shapes.
