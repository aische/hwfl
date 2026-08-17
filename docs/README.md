# Documentation (maintainers)

This folder is **internals**: session state, spec, architecture, bug
report, decision log. Authors use the [user manual](../manual/README.md).

Start sessions from [STATUS.md](STATUS.md) and [TASKS.md](TASKS.md).
Code and tests own behaviour.

## Map

| File | Purpose |
| ---- | ------- |
| [idea.md](idea.md) | Vision, goals, non-goals |
| [STATUS.md](STATUS.md) | Current focus (rewrite often) |
| [TASKS.md](TASKS.md) | Active backlog only |
| [architecture.md](architecture.md) | Layers, host/stdlib policy, package layout |
| [hwfi-reference.md](hwfi-reference.md) | What to reuse / avoid from hwfi |
| [BUG_REPORT.md](BUG_REPORT.md) | Findings (H-/M-/L-); mark fixed here |
| [log/](log/) | Decision / milestone log + archive |
| [spec/](spec/) | Normative specification |

### Spec suite (`spec/`)

| Doc | Topic |
| --- | ----- |
| [00-overview.md](spec/00-overview.md) | Index, glossary, document status |
| [01-modules.md](spec/01-modules.md) | Markdown module layout & frontmatter |
| [02-language.md](spec/02-language.md) | Kernel syntax & semantics |
| [03-types.md](spec/03-types.md) | Type system |
| [04-effects.md](spec/04-effects.md) | Capabilities / effect lattice |
| [05-host-ops.md](spec/05-host-ops.md) | Host primitives (fs, llm, exec, …) |
| [06-runtime.md](spec/06-runtime.md) | Interpreter, frames, resume, `par`, confirm |
| [07-observability.md](spec/07-observability.md) | Spans, traces, CLI show |
| [08-llm-provider.md](spec/08-llm-provider.md) | Provider adapter (llm-simple + swap) |
| [09-cli.md](spec/09-cli.md) | Command-line interface |
| [10-acceptance.md](spec/10-acceptance.md) | Fitness metrics & non-acceptance |
| [11-grammar.ebnf](spec/11-grammar.ebnf) | Non-normative grammar sketch |
| [12-example-suite.md](spec/12-example-suite.md) | Language contracts (E01–E25) |
| [13-mcp.md](spec/13-mcp.md) | MCP **client** (stdio) |

When a host op or kernel rule changes, update **spec §05 (or the matching
numbered spec)** and the matching [manual](../manual/README.md) page — not
a third catalog.

## Workflow

- Start sessions from `STATUS.md` + `TASKS.md`
- Read `spec/` only when the task needs requirements
- Read `idea.md` / `architecture.md` if scope or boundaries are unclear
- Read `hwfi-reference.md` before copying behaviour from the hwfi repo
- On meaningful finish: rewrite STATUS, trim TASKS, log decisions
- Archive finished plans and long Done lists under `log/archive/`

## Constraints (sticky)

- Implemented in **Haskell** (GHC2021)
- Default LLM backend: **`llm-simple`**, behind a replaceable provider
  interface ([spec/08-llm-provider.md](spec/08-llm-provider.md))
- No GUI in v0; no Servant/multi-tenant runtime **in this repo**
- Do not reintroduce hwfi’s step DSL as the computation substrate
