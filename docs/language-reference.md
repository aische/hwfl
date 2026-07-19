# Language reference

One-card overview of the hwfl kernel surface.

## Keywords

`let` · `in` · `fun` · `type` · `match` · `with` · `if` · `then` · `else` ·
`par` · `for` · `join` · `task` · `try` · `catch` · `confirm` · `choice` ·
`true` · `false`

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
| `text.trim` | `String -> String` |
| `text.starts_with` | `String -> String -> Bool` |
| `text.normalize_token` | strip wrap punct / backticks |
| `text.is_qname` | conservative `root/seg…` module qname |
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
| `fs.edit` | Write | `{ path, old, new } -> { ok: Bool }` (literal replace-all; `ok` iff ≥1 hit) |
| `fs.patch` | Write | `{ path, hunks: List<{ old, new }> } -> { ok, applied, error }` (each `old` unique after prior hunks; atomic) |
| `fs.grep` | Read | `{ pattern, glob } -> List<{ file, line, text }>` (empty `glob` = whole workspace) |
| `fs.mkdir` | Write | `(path: FileRef) -> ()` (creates parents) |
| `fs.copy` | Write | `{ src, dst, overwrite?, exclude? } -> ()` (file or recursive tree; `exclude` = path prefixes under the tree root) |
| `fs.move` | Write | `{ src, dst } -> ()` (fails if `dst` exists) |
| `fs.exists` | Read | `(path: FileRef) -> Bool` |
| `fs.stat` | Read | `(path: FileRef) -> { exists: Bool, kind: String, size: Int }` (`kind` is `file` / `dir` / `""`) |

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
| `llm.chat_messages` | Net | `{ system, messages: List<{ role, content }>, model } -> String` |
| `llm.object` | Net | `{ prompt, schema, model } -> T` when `schema = schema(T)` (else `Json`) |
| `llm.agent` | Net | `{ system, prompt, tools, model, max_rounds } -> { text, rounds }` |
| `llm.agent_object` | Net | `{ …, schema } -> { value: T, rounds }` (synthetic `submit` tool) |

### Human / observability / meta

| Op | Effects | Signature |
|----|---------|-----------|
| `human.confirm` | Human | `{ title, detail } -> Bool` |
| `human.choice` | Human | `{ title, detail, options: List<String> } -> String` |
| `human.ask` | Human | `{ prompt, detail } -> String` |
| `obs.log` | — | `{ level, message, fields } -> ()` |
| `obs.span` | — | `(name, fun () -> a) -> a` |
| `meta.check_module` | Meta, Read | `(path: FileRef) -> { ok, error, name }` |
| `meta.check_project` | Meta, Read | `(path: FileRef) -> { ok, error }` |
| `meta.invoke` | Meta, Read | `{ project, workspace, inputs? } -> { ok, run_id, status, outcome, error }` |
| `meta.list_runs` | Meta, Read | `{ workspace } -> { ok, runs, error }` |
| `meta.read_spans` | Meta, Read | `{ run_id, workspace, name_prefix?, kind?, limit? } -> { ok, spans, error }` |
| `meta.read_snapshot` | Meta, Read | `{ run_id, workspace } -> { ok, snapshot, error }` |

`meta.invoke` runs a nested project directory or `.md` module via the same
path as the library driver. `project` and `workspace` are workspace-relative
`FileRef`s (caller materializes them). `inputs` is an optional record passed
to child `main`. Returns a recoverable result (`ok` / `status`); child
`run_id` lives under the child workspace’s `.hwfl/runs/`.

`meta.list_runs` lists run metas under `.hwfl/runs` for a workspace-relative
root. `meta.read_spans` returns span records for one run (optional name /
kind prefix filters and limit). `meta.read_snapshot` returns a redacted Json
encoding of the run snapshot (status, seq, machine, …) — never cleartext
secrets. Missing run / snapshot → `ok = false`.

### Skills

| Op | Effects | Signature |
|----|---------|-----------|
| `skill.discover` | Meta, Read | `{ query, kinds, limit } -> { ok, skills, error }` |
| `skill.load` | Meta, Read | `{ id } -> { ok, kind, loaded, content, error }` |

`skills` entries from discover are metadata only (`id`, `kind`, `summary`,
`tags`, `checked`, `agent_eligible`). Inside an agent, `load` injects
instruction context or expands tools; outside, instruction returns `content`.
List both ops in `tools = […]` when needed — no auto-injection. Budgets:
optional `project.json` `skills` stanza.

## Control sugar

```text
par(max = N) for x in xs { e }
join { task { e1 }; task { e2 } }
confirm { title = …, detail = … }
choice { title = …, detail = …, options = […] }
```

`confirm` / `human.confirm` / `choice` / `human.choice` / `human.ask` inside
`par` freezes the pool. Resolve with `hwfl approve --yes|--no`,
`hwfl choose --select <option>`, or `hwfl reply --text <string>` respectively.

**Runtime note:** `par(max = N)` caps active branches; result order
matches input order. The runtime steps one branch transition at a time
(cooperative). Overlapping blocking host IO across branches is not
supported.

## Effects

`Read` · `Write` · `Net` · `Exec` · `Human` · `Meta` · `Parallel`

Module `effects:` is a ceiling. `Exec` also requires non-empty
`project.json` `exec.allow`.
