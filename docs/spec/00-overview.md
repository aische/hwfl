# 00 — Overview

Normative product summary for **hwfl** (provisional name). Other `spec/*`
files refine this. Conflicts: newer dated decision-log entries win until
specs are updated.

## 1. Product summary

A command-line engine, written in Haskell (GHC2021), that:

1. Loads a **project** of markdown modules (+ small JSON config).
2. **Checks** the project (parse, types, effects, reference graph) before
   any host side effect.
3. **Evaluates** module entrypoints in a frame/stack interpreter.
4. Treats LLM, filesystem, process, human confirm, and parallelism as
   **host effects** with span instrumentation.
5. **Persists** machine snapshots so runs are resumable after crash/abort.
6. Exposes richer **observability** than a flat event list (span trees).

Non-goals for v0: GUI, distributed execution, package registry,
multi-tenant isolation, embedding JS/Python/Lua VMs.

## 2. Design principles

1. **Prose is data.** Markdown sections bind as strings for prompts/docs.
2. **Code is a real language.** Locals, functions, match, and collections
   are not optional — they are why we left the step DSL.
3. **Effects are explicit.** Modules declare allowed capabilities; host
   ops require them.
4. **Resume at effects.** Pure reduction is ephemeral; host ops are
   transitions.
5. **Stdlib in-language.** Host ops stay rare and privileged.
6. **Providers are adapters.** Workflows never depend on a vendor SDK.
7. **Check before bill.** Static failure beats runtime surprise.

## 3. Glossary

| Term                    | Meaning                                                    |
| ----------------------- | ---------------------------------------------------------- |
| **Module**              | One markdown file declaring an interface + script / types  |
| **Project**             | Directory with `project.json` + modules                    |
| **Kernel**              | The ML expression language inside ` ```hwfl ` fences       |
| **Host op**             | Runtime-provided effectful primitive                       |
| **Effect / capability** | Element of the effect lattice (`Read`, `Net`, …)           |
| **Transition**          | Atomic durable step (usually one host op or control event) |
| **Frame**               | Continuation / stack frame in the machine                  |
| **Snapshot**            | Serializable machine state for resume                      |
| **Span**                | Timed, nested observation unit for a region or host op     |
| **Provider**            | Implementation of `LlmProvider` (default: llm-simple)      |

## 4. Document status

| Doc                          | Normative?                                           |
| ---------------------------- | ---------------------------------------------------- |
| `00`–`10`, `11-grammar`      | Yes for v0 intent                                    |
| `12-example-suite`           | Design oracle; syntax may evolve but contracts stick |
| `idea.md`, `architecture.md` | Guiding; defer to numbered specs on conflict         |

## 5. Versioning

- Spec targets **v0** implementation milestones in
  [10-acceptance.md](10-acceptance.md).
- Features marked **[defer]** are intentionally out of v0.
- Breaking changes to snapshot JSON require a format version bump and a
  logged decision.
