# Effects

Effects are capabilities. A module’s `effects:` frontmatter is a
**ceiling**: every top-level `fun` (including `main`) must stay inside it.
Project `effects.deny` always wins. Omitting `effects` uses
`project.json` `effects.default`.

There is no `Pure` keyword. An empty list (`effects: []`) means no host
ops.

## Effect kinds

| Effect | Meaning | Typical ops |
|--------|---------|-------------|
| `Read` | Read workspace files | `fs.read`, `fs.list`, `fs.find`, `fs.grep`, `fs.exists`, `fs.stat`, `fs.read_slice` |
| `Write` | Mutate workspace files | `fs.write`, `fs.edit`, `fs.patch`, `fs.mkdir`, `fs.copy`, `fs.move`, `fs.remove` |
| `Net` | LLM provider | `llm.*` |
| `Exec` | Process spawn and MCP stdio | `exec.run`, `mcp.call`, `mcp.tools` |
| `Human` | Operator gates | `confirm`, `choice`, `human.ask` |
| `Parallel` | Structured concurrency | `par`, `join` |
| `Meta` | Other projects / runs | `meta.*`, `skill.*` |

`obs.log` and `obs.span` do not need an effect in `effects:` (they still
show up in `hwfl show`).

## Extra policy

- **`Exec`**: `exec.run` also needs a non-empty `project.json` `exec.allow`.
  `mcp.*` needs `mcp.servers.<id>` and `mcp.allow` (bare basenames).
- **Same-project call** `workflows/inner(inputs)` unions the callee’s
  effects into the caller. It does **not** require `Meta`.
- **`meta.invoke`** starts a **nested** project/module (own run id under
  the child workspace). That is `Meta`.

## Inference

Effects of a `fun` are those of the host ops, `par`/`join`/`confirm`,
and functions it calls. If that set is wider than the module `effects:`
list, check fails.

Function types may mention effects (`(FileRef) -[Read]-> { text: String }`),
but top-level `fun`s usually omit that and let inference plus the module
ceiling do the work.

## Examples

```yaml
effects: []                          # pure
effects: [Read, Net]                 # summarise a file with an LLM
effects: [Read, Write, Net, Exec]    # coding agent
effects: [Human, Net]                # chat + confirm
effects: [Exec, Parallel, Human]     # par + confirm + exec
```

Declare what `main` (and any export called from outside) actually needs.
Library internals can be tighter than the module ceiling; they cannot be
wider.
