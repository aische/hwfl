# New project documentation pack

Provisional working name: **hwfl** (Haskell workflow language - although it looks more like ML, but implemented in Haskell)

This folder is **`docs/`** in the hwfl repository. Keep the **hwfi** repo
nearby as a behavioural / design reference (see [hwfi-reference.md](hwfi-reference.md)).
Start sessions from [STATUS.md](STATUS.md) and [TASKS.md](TASKS.md).

## Doc map

| File                                   | Purpose                          |
| -------------------------------------- | -------------------------------- |
| [idea.md](idea.md)                     | Vision, goals, non-goals         |
| [STATUS.md](STATUS.md)                 | Current focus (rewrite often)    |
| [TASKS.md](TASKS.md)                   | Active backlog only              |
| [architecture.md](architecture.md)     | Layers, components, boundaries   |
| [hwfi-reference.md](hwfi-reference.md) | What to reuse / avoid from hwfi  |
| [skills-plan.md](skills-plan.md)       | Planned skills catalog + agent load |
| [log/](log/)                           | Decision / milestone log         |
| [spec/](spec/)                         | Normative specification          |
| [examples/](examples/)                 | Design examples (contracts)      |
| [stdlib.md](stdlib.md)                 | What belongs in-language vs host |
| [language-reference.md](language-reference.md) | Keywords, types, prelude + host ops |

### Spec suite (`spec/`)

| Doc                                             | Topic                                       |
| ----------------------------------------------- | ------------------------------------------- |
| [00-overview.md](spec/00-overview.md)           | Product summary, principles, glossary       |
| [01-modules.md](spec/01-modules.md)             | Markdown module layout & frontmatter        |
| [02-language.md](spec/02-language.md)           | Kernel syntax & semantics                   |
| [03-types.md](spec/03-types.md)                 | Type system                                 |
| [04-effects.md](spec/04-effects.md)             | Capabilities / effect lattice               |
| [05-host-ops.md](spec/05-host-ops.md)           | Host primitives (fs, llm, exec, …)          |
| [06-runtime.md](spec/06-runtime.md)             | Interpreter, frames, resume, `par`, confirm |
| [07-observability.md](spec/07-observability.md) | Spans, traces, CLI show                     |
| [08-llm-provider.md](spec/08-llm-provider.md)   | Provider adapter (llm-simple + swap)        |
| [09-cli.md](spec/09-cli.md)                     | Command-line interface                      |
| [10-acceptance.md](spec/10-acceptance.md)       | Acceptance criteria & milestones            |
| [11-grammar.ebnf](spec/11-grammar.ebnf)         | Concrete grammar sketch                     |
| [12-example-suite.md](spec/12-example-suite.md) | 20 design programs + contracts              |

## Documentation workflow

Same discipline as hwfi (see `cursor-scaffold/rules/project-docs.mdc`):

- Start sessions from `STATUS.md` + `TASKS.md`
- Code/tests own behaviour; don’t edit specs for every tweak
- On meaningful finish: rewrite STATUS, trim TASKS, log decisions

## Constraints (sticky)

- Implemented in **Haskell** (GHC2021)
- Default LLM backend: **`llm-simple`** (`^>=0.1.0.1`), behind a replaceable
  provider interface ([spec/08-llm-provider.md](spec/08-llm-provider.md))
- No GUI in v0
- hwfi remains the reference implementation for resume / confirm / sandbox ideas
