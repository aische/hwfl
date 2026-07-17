# Language reference

One-card overview of the hwfl kernel surface. Behaviour lives in code +
`docs/spec/`; this card is for quick lookup.

## Keywords

`let` · `in` · `fun` · `type` · `match` · `with` · `if` · `then` · `else` ·
`par` · `for` · `join` · `task` · `try` · `catch` · `confirm` · `true` ·
`false`

(`null` is JSON interop only; prefer `Option` / `Result` in surface code.)

## Builtin types

| Type | Notes |
|------|--------|
| `Unit` | `()` |
| `Bool` | |
| `Int` | |
| `Float` | |
| `String` | UTF-8 |
| `Bytes` | no implicit string coercion |
| `Json` | untyped JSON |
| `FileRef` | workspace-relative path (string at runtime) |
| `List<T>` | |
| `{ f: T, … }` | record |
| `Option<T>` | |
| `Result<T, E>` | |
| `Secret<T>` | non-interpolable; redacted in spans |
| `Schema` | from `schema(T)` |
| `ToolSpec` | from `tool(f)` |

## Pure prelude

No snapshot boundary.

| Op | Signature |
|----|-----------|
| `list.length` | `List<T> -> Int` |
| `list.concat` | `List<T> -> List<T> -> List<T>` |
| `text.metrics` | `String -> { chars, tokens, lines, entropy, uniqueness }` |
| `text.similarity` | `String -> String -> Float` |
| `text.contains` | `String -> String -> Bool` |
| `text.split_sentences` | `String -> List<String>` |
| `text.words` | `String -> List<String>` |
| `text.strip_suffix` | `String -> String -> String` |
| `md.sections` | `String -> List<{ slug, title, body }>` |
| `json.encode` | encodable value → `String` |
| `tool` | function / host op → `ToolSpec` |
| `schema` | type → `Schema` |
| `+` `-` `*` `/` | Int / Float (same-sort) |
| `==` `!=` `<` `<=` `>` `>=` | |
| `&&` `\|\|` `not` | Bool |

Ambient `ctx.run.id` / `ctx.run.started_at` are injected at runtime.

## Host ops

Each call is a transition (snapshot + span) unless noted.

### Filesystem

| Op | Effects | Signature |
|----|---------|-----------|
| `fs.read` | Read | `(path: FileRef) -> { text: String }` |
| `fs.write` | Write | `{ path: FileRef, text: String } -> ()` |
| `fs.find` | Read | `{ glob: String } -> List<FileRef>` (`**/*.ext` / `*.ext`; agent-tool eligible) |
| `fs.list` | Read | `(path: FileRef) -> List<{ name: String, kind: String }>` |
| `fs.edit` | Write | `{ path, old, new } -> { ok: Bool }` (literal replace; `ok` iff ≥1 hit) |
| `fs.grep` | Read | `{ pattern, glob } -> List<{ file, line, text }>` (empty `glob` = whole workspace) |

Paths are sandboxed to the workspace root (symlink escape fails).

### Process

| Op | Effects | Signature |
|----|---------|-----------|
| `exec.run` | Exec | `{ program, args, stdin } -> { exit_code, stdout, stderr, timed_out }` |

Requires `project.json` `exec.allow` (non-empty). Program must be a bare
basename on the allowlist. Child env = keys in `exec.env` only.

```json
"exec": {
  "allow": ["echo", "cabal"],
  "env": ["PATH"],
  "timeout_ms": 120000,
  "max_output_bytes": 1048576,
  "confirm": true
}
```

`confirm` defaults to `true` (pause for `hwfl approve` before spawn). Set
`false` for CI.

### LLM

| Op | Effects | Signature |
|----|---------|-----------|
| `llm.chat` | Net | `{ system, prompt, model } -> String` |
| `llm.object` | Net | `{ prompt, schema, model } -> T` when `schema = schema(T)` (else `Json`) |
| `llm.agent` | Net | `{ system, prompt, tools, model, max_rounds } -> { text, rounds }` |
| `llm.agent_object` | Net | `{ …, schema } -> { value: T, rounds }` (synthetic `submit` tool) |

### Human / observability / meta

| Op | Effects | Signature |
|----|---------|-----------|
| `human.confirm` | Human | `{ title, detail } -> Bool` |
| `obs.log` | — | `{ level, message, fields } -> ()` |
| `obs.span` | — | `(name, fun () -> a) -> a` |
| `meta.check_module` | Meta, Read | `(path: FileRef) -> { ok, error, name }` |
| `meta.check_project` | Meta, Read | `(path: FileRef) -> { ok, error }` |

### Skills

| Op | Effects | Signature |
|----|---------|-----------|
| `skill.discover` | Meta, Read | `{ query, kinds, limit } -> { ok, skills, error }` |
| `skill.load` | Meta, Read | `{ id } -> { ok, kind, loaded, content, error }` |

`skills` entries from discover are metadata only (`id`, `kind`, `summary`,
`tags`, `checked`, `agent_eligible`). Inside an agent, `load` injects
instruction context or expands tools; outside, instruction returns `content`.
List both ops in `tools = […]` when needed — no auto-injection. Budgets:
optional `project.json` `skills` stanza. See [skills-plan.md](skills-plan.md).

## Control sugar

```text
par(max = N) for x in xs { e }
join { task { e1 }; task { e2 } }
confirm { title = …, detail = … }
```

`confirm` / `human.confirm` inside `par` freezes the pool.

## Effects

`Read` · `Write` · `Net` · `Exec` · `Human` · `Meta` · `Parallel`

Module `effects:` is a ceiling. `Exec` also requires non-empty
`project.json` `exec.allow`.
