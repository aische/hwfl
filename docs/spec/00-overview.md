# 00 — Overview

Index for the numbered specs. Product intent: [idea.md](../idea.md).
Layers and stdlib policy: [architecture.md](../architecture.md). Author
surface: [manual](../../manual/README.md).

Conflicts: newer dated [log](../log/) entries win until specs are
updated. Code and tests own behaviour.

## 1. What this spec suite covers

hwfl is a small programming language + durable interpreter (Haskell
library + CLI). Specs `01`–`09` and `13` are **normative for v0**. They
define modules, kernel, types, effects, host ops, runtime, observability,
provider boundary, CLI, and the MCP client.

Non-goals for this repo: GUI/IDE shell, Servant/HTTP in-tree, distributed
multi-tenant runtime, package registry, embedding JS/Python/Lua VMs.
See [idea.md](../idea.md).

## 2. Glossary

| Term | Meaning |
| ---- | ------- |
| **Module** | One markdown file declaring an interface + script / types |
| **Project** | Directory with `project.json` + modules |
| **Kernel** | The ML expression language inside ` ```hwfl ` fences |
| **Host op** | Runtime-provided effectful primitive |
| **Effect / capability** | Element of the effect lattice (`Read`, `Net`, …) |
| **Transition** | Atomic durable step (usually one host op or control event) |
| **Frame** | Continuation / stack frame in the machine |
| **Snapshot** | Serializable machine state for resume |
| **Span** | Timed, nested observation unit for a region or host op |
| **Provider** | Implementation of `LlmProvider` (default: llm-simple) |
| **Skill** | Project `skills/*` module: callable tool or instruction guide |

## 3. Document status

| Doc | Normative? |
| --- | ---------- |
| `01`–`09`, `13-mcp` | Yes for v0 |
| `10-acceptance` | Fitness metrics + explicit non-acceptance |
| `11-grammar` | **No** — sketch; parser is source of truth |
| `12-example-suite` | Contracts (E01–E25); syntax may drift |
| `idea.md`, `architecture.md` | Guiding; defer to numbered specs on conflict |

Author catalog of names and signatures: [manual/cheatsheet.md](../../manual/cheatsheet.md).
When an op changes, patch **this spec suite** and the matching manual
page in the same change.

## 4. Versioning

- Features marked **[defer]** are intentionally out of v0.
- Breaking changes to snapshot JSON require a format version bump and a
  logged decision (`snapshot_format` is `1` today).
