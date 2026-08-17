# hwfl

hwfl is a small typed language for durable workflows. You write markdown
modules: YAML frontmatter, prose sections, and one `hwfl` code fence. The
interpreter checks the program, then runs it with checkpointed host effects
(files, models, processes, humans, MCP).

This book is the **author manual**. Open the [cheatsheet](cheatsheet.md)
while you write. Use [syntax](language.md) when you need a form. Use the
[library](library/README.md) pages for arguments, errors, and examples.

## Capability map

| I want to… | Use |
|------------|-----|
| Shape of a program | [Projects](project.md) + `fun main` |
| Bind locals / functions | `let`, `fun`, `type` — [syntax](language.md) |
| Branch | `if`, `match` |
| Read or write files | [`fs.*`](library/fs.md) |
| Call a model | [`llm.chat`](library/llm.md), `llm.object` |
| Tool-using agent | [`llm.agent`](library/llm.md) + `tool(…)` |
| Pause for a human | [`confirm`](library/human.md), `choice`, `human.ask` |
| Run a process | [`exec.run`](library/exec.md) |
| Talk to MCP | [`mcp.call`](library/mcp.md), `mcp.tools` |
| Compose workflows | import + `qname(inputs)`, or [`meta.invoke`](library/meta.md) |
| Parallel map | `par` / `join` — [syntax](language.md) |
| List / option helpers | [`hwfl/list`](library/stdlib.md) (import; not prelude) |
| Convert Int / Float | [`int.to_float`](library/prelude.md), `float.round` |
| Run it | [CLI](cli.md) |

## How to use this book

| Page | Open when |
|------|-----------|
| [Cheatsheet](cheatsheet.md) | Always — every name and signature, `Ctrl-F` |
| [Syntax](language.md) | Writing a construct (`let`, `match`, records, …) |
| [Types](types.md) / [Effects](effects.md) | Declaring `inputs`, `outputs`, `effects` |
| A [library](library/README.md) page | Calling a host op or stdlib function |
| [Cookbook](cookbook.md) | Copying a whole pattern |

## Mental model

| Piece | Role |
|-------|------|
| **Module** | One markdown file: frontmatter + prose + one ` ```hwfl ` fence |
| **Project** | Directory with `project.json` plus modules under `workflows/`, `lib/`, `types/`, `tools/`, `skills/` |
| **Workspace** | Sandbox for `fs.*` / `exec.*`. Distinct from the project (code) unless you point them at the same directory |
| **Run** | One execution. Id printed as `hwfl run: run_id=…`. State under `.hwfl/runs/<id>/` |
| **Host op** | Privileged effect (`fs.read`, `llm.chat`, …). Each call is saved so resume does not redo it |
| **Prelude** | Always in scope (`list.length`, `text.trim`, `+`, …) |
| **Stdlib** | Markdown modules you import (`hwfl/list`, …) |

**Check before run.** `hwfl check` parses, types, and checks effects with no host side effects. `hwfl run` checks first unless you pass `--no-check`.

**Resume.** Host ops, `par`/`join`, and human gates are saved. Changing code or frontmatter after a pause refuses resume (exit `4`). Prose-only edits do not.

## A complete module

````markdown
---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
effects: [Read, Net]
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## body

```hwfl
fun main(inputs): { summary: String } =
  let contents = fs.read(inputs.path)
  let summary = llm.chat(
    system = @system,
    prompt = $"Summarise the following:\n\n{contents.text}",
    model = "deepseek4flash"
  )
  { summary }
```
````

`@system` is the markdown section titled “system”. `model` is a name from
`model-catalog.json`. Run it with [CLI](cli.md).

## Layers

| Layer | How you get it |
|-------|----------------|
| Prelude / host | Always in scope: `list.length`, `fs.read`, `+` |
| Stdlib pack | `imports: [hwfl/list]` then `hwfl/list.map(…)` |
| Project `lib/` | `imports: [lib/foo]` then `lib/foo.bar(…)` |

If a signature here disagrees with `hwfl check`, the checker wins.
