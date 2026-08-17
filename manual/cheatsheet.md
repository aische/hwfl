# Cheatsheet

Every name in the language. `?` means the field may be omitted. Effects
column is empty for pure ops. Host calls are checkpointed unless noted.

Jump: [keywords](#keywords) · [types](#types) · [operators](#operators) ·
[prelude](#prelude) · [fs](#fs) · [llm](#llm) · [exec](#exec) ·
[human](#human) · [obs](#obs) · [meta](#meta) · [skill](#skill) ·
[mcp](#mcp) · [stdlib](#stdlib) · [A–Z](#a-z)

## Keywords

| Form | Meaning |
|------|---------|
| `let x = e in e` | Bind. Sequential `let` (no `in`) if the body starts on a later line |
| `fun f(x: T): U = e` | Top-level function (return type required) |
| `fun (x: T): U => e` | Lambda (`=` also accepted) |
| `type Name = T` | Type alias |
| `if e then e else e` | Both branches required |
| `match e with \| p => e` | Pattern match |
| `par(max = N) for x in xs { e }` | Parallel map → `List` |
| `join { task { e } task { e } }` | Fixed-arity parallel → `List` |
| `try e catch (err) => e` | Catchable host/provider/sandbox errors (`err: String`) |
| `confirm { title = …, detail? = … }` | Human yes/no → `Bool` |
| `choice { title = …, options = …, detail? = … }` | Human pick → `String` |
| `true` `false` | `Bool` |
| `schema(T)` | Check-time `Schema` |
| `tool(f)` | Function or host op → `ToolSpec` |
| `$"…{e}…"` | Interpolation → `String` |
| `@slug` | Markdown section body → `String` |

`in`, `with`, `then`, `else`, `for`, `task`, `catch` are reserved and only
legal in those forms.

## Types

| Type | Notes |
|------|--------|
| `Unit` | `()` |
| `Bool` | |
| `Int` | Arbitrary precision integers |
| `Float` | Decimal literals (`1.0`) |
| `String` | UTF-8; `"…"` or `"""…"""` |
| `Bytes` | No surface literal; no implicit string coercion |
| `Json` | Untyped JSON |
| `FileRef` | Workspace-relative path; string literals coerce at `FileRef` parameters |
| `List<T>` | Homogeneous; index `xs[i]` |
| `{ f: T, … }` | Record type (`:`). Value uses `=` |
| `Option<T>` | `Some(x)` / `None` |
| `Result<T, E>` | `Ok(x)` / `Err(e)` |
| `Secret<T>` | Not interpolable; redacted in spans |
| `Schema` | From `schema(T)` |
| `ToolSpec` | From `tool(f)` |
| `Turn` | Agent transcript turn |
| `(T) -> U` | Function |
| `(T) -[Read, Net]-> U` | Function with effects (optional annotation) |

Ambient: `ctx.run.id : String`, `ctx.run.started_at : String`.

## Operators

| Op | Sorts | Result |
|----|-------|--------|
| `+` `-` `*` `/` | Same sort: `Int` or `Float` (no mix, no `String +`) | Same numeric type |
| `==` `!=` | Comparable: bases, `List<T>`, records; `String` ≅ `FileRef` | `Bool` |
| `<` `<=` `>` `>=` | Same sort among `Int` \| `Float` \| `String` \| `FileRef` | `Bool` |
| `&&` `\|\|` | `Bool` (short-circuit) | `Bool` |
| `not` | `Bool -> Bool` | `Bool` |

Spaced `a / b` divides. Tight `a/b` is a module qname. Bare operators
(`let f = +`) are rejected — apply them.

## Prelude

Always in scope. Pure. No snapshot.

| Op | Signature |
|----|-----------|
| `list.length` | `List<a> -> Int` |
| `list.concat` | `(List<a>, List<a>) -> List<a>` |
| `text.metrics` | `String -> { chars: Int, tokens: Int, lines: Int, entropy: Float, uniqueness: Float }` |
| `text.similarity` | `String -> String -> Float` |
| `text.contains` | `String -> String -> Bool` |
| `text.split_sentences` | `String -> List<String>` |
| `text.words` | `String -> List<String>` |
| `text.strip_suffix` | `String -> String -> String` |
| `text.trim` | `String -> String` |
| `text.starts_with` | `String -> String -> Bool` |
| `text.normalize_token` | `String -> String` |
| `text.is_qname` | `String -> Bool` |
| `md.sections` | `String -> List<{ slug: String, title: String, body: String }>` |
| `json.encode` | encodable value → `String` |
| `tool` | `(a) -> b` or host op → `ToolSpec` |
| `schema` | type → `Schema` |

Curried prelude ops accept either `text.trim(s)` or `text.contains(a, b)`.

## fs

Effect `Read` or `Write`. Sandboxed to the workspace. Details:
[fs](library/fs.md).

| Op | Eff | Signature |
|----|-----|-----------|
| `fs.read` | Read | `(path: FileRef) -> { text: String }` |
| `fs.read_slice` | Read | `{ path: FileRef, start_line: Int, end_line: Int } -> { text: String }` |
| `fs.write` | Write | `{ path: FileRef, text: String } -> ()` |
| `fs.list` | Read | `(path: FileRef) -> List<{ name: String, kind: String }>` |
| `fs.find` | Read | `{ glob: String } -> List<FileRef>` |
| `fs.grep` | Read | `{ pattern: String, glob: String } -> List<{ file: String, line: Int, text: String }>` |
| `fs.edit` | Write | `{ path: FileRef, old: String, new: String } -> { ok: Bool }` |
| `fs.patch` | Write | `{ path: FileRef, hunks: List<{ old: String, new: String }> } -> { ok: Bool, applied: Int, error: String }` |
| `fs.mkdir` | Write | `(path: FileRef) -> ()` |
| `fs.copy` | Write | `{ src: FileRef, dst: FileRef, overwrite?: Bool, exclude?: List<String> } -> ()` |
| `fs.move` | Write | `{ src: FileRef, dst: FileRef } -> ()` |
| `fs.remove` | Write | `(path: FileRef) -> ()` |
| `fs.exists` | Read | `(path: FileRef) -> Bool` |
| `fs.stat` | Read | `(path: FileRef) -> { exists: Bool, kind: String, size: Int }` |

`fs.grep` `glob = ""` searches the whole workspace. `fs.find` / `fs.grep`
globs: `**/*.ext` or `*.ext`.

## llm

Effect `Net`. `model` is a `model-catalog.json` name. Details:
[llm](library/llm.md), [agent context](library/llm-context.md).

| Op | Signature |
|----|-----------|
| `llm.chat` | `{ system: String, prompt: String, model: String } -> String` |
| `llm.chat_messages` | `{ system: String, messages: List<{ role: String, content: String }>, model: String } -> String` |
| `llm.object` | `{ prompt: String, schema: Schema, model: String } -> T` when `schema = schema(T)` (else `Json`) |
| `llm.agent` | `{ system, prompt, tools: List<ToolSpec>, model, max_rounds?: Int, history?: List<Turn>, context_window?: Int, max_tool_result_chars?: Int, consolidate?: String, max_pins?: Int, max_summary_chars?: Int } -> { text: String, rounds: Int, history: List<Turn> }` |
| `llm.agent_object` | same as agent + required `schema` → `{ value: T, rounds: Int, history: List<Turn> }` |

Defaults: `max_rounds = 8`. `consolidate = "heuristic"` requires
`context_window`.

## exec

Effect `Exec`. Requires `project.json` `exec.allow`. Details:
[exec](library/exec.md).

| Op | Signature |
|----|-----------|
| `exec.run` | `{ program: String, args: List<String>, stdin: String } -> { exit_code: Int, stdout: String, stderr: String, timed_out: Bool }` |

`program` is a bare basename on the allowlist. `confirm` defaults to
`true` (pause for `hwfl approve` before spawn).

## human

Effect `Human`. Sugar `confirm` / `choice` equals `human.confirm` /
`human.choice`. Details: [human](library/human.md).

| Op | Signature |
|----|-----------|
| `human.confirm` | `{ title: String, detail?: String } -> Bool` |
| `human.choice` | `{ title: String, options: List<String>, detail?: String } -> String` |
| `human.ask` | `{ prompt: String, detail?: String } -> String` |

Resolve with `hwfl approve --yes\|--no`, `hwfl choose --select`, `hwfl reply --text`.

## obs

Not a checkpoint. Details: [obs](library/obs.md).

| Op | Signature |
|----|-----------|
| `obs.log` | `{ level: String, message: String, fields?: record \| Json } -> ()` also `obs.log(level, message)` |
| `obs.span` | `(name: String, fun () -> a) -> a` (curried `obs.span(name)(thunk)` also works) |

## meta

Effects `Meta` + `Read`. Nested project runs — not same-project
`qname(inputs)`. Details: [meta](library/meta.md).

| Op | Signature |
|----|-----------|
| `meta.check_module` | `(path: FileRef) -> { ok: Bool, error: String, name: String }` |
| `meta.check_project` | `(path: FileRef) -> { ok: Bool, error: String }` |
| `meta.invoke` | `{ project: FileRef, workspace: FileRef, inputs?: record \| Json } -> { ok: Bool, run_id: String, status: String, outcome: Json, error: String }` |
| `meta.list_runs` | `{ workspace: FileRef } -> { ok: Bool, runs: List<{ run_id, status, entry, started_at, project_hash: String }>, error: String }` |
| `meta.read_spans` | `{ run_id: String, workspace: FileRef, name_prefix?: String, kind?: String, limit?: Int } -> { ok: Bool, spans: List<Span>, error: String }` |
| `meta.read_snapshot` | `{ run_id: String, workspace: FileRef } -> { ok: Bool, snapshot: Json, error: String }` |

Span entry: `{ op, id, parent_id, name, kind, t_start, t_end, status, attrs: Json, snapshot_seq: Int }`.

## skill

Effects `Meta` + `Read`. List both ops in `tools = […]` when an agent
needs them. Details: [skill](library/skill.md).

| Op | Signature |
|----|-----------|
| `skill.discover` | `{ query: String, kinds: List<String>, limit: Int } -> { ok: Bool, skills: List<{ id, kind, summary: String, tags: List<String>, checked: Bool, agent_eligible: Bool }>, error: String }` |
| `skill.load` | `{ id: String } -> { ok: Bool, kind: String, loaded: Bool, content: String, error: String }` |

## mcp

Effect `Exec`. Requires `project.json` `mcp`. Details: [mcp](library/mcp.md).

| Op | Signature |
|----|-----------|
| `mcp.call` | `{ server: String, name: String, arguments: Json \| record, schema?: Schema } -> Json` (→ `T` when `schema = schema(T)`) |
| `mcp.tools` | `{ server: String, names?: List<String>, bind?: Json \| record } -> List<ToolSpec>` |

## Stdlib

Import first. Call `hwfl/list.map(…)`. Do not call helpers named `*_go`.
Details: [stdlib](library/stdlib.md).

### `hwfl/list`

| Fun | Signature |
|-----|-----------|
| `is_empty` | `List<a> -> Bool` |
| `length` | `List<a> -> Int` |
| `append` | `(List<a>, List<a>) -> List<a>` |
| `map` | `(List<a>, (a) -> b) -> List<b>` |
| `filter` | `(List<a>, (a) -> Bool) -> List<a>` |
| `flat_map` | `(List<a>, (a) -> List<b>) -> List<b>` |
| `fold_left` | `(List<a>, b, (b) -> (a) -> b) -> b` |
| `take` | `(List<a>, Int) -> List<a>` |
| `drop` | `(List<a>, Int) -> List<a>` |
| `reverse` | `List<a> -> List<a>` |
| `any` | `(List<a>, (a) -> Bool) -> Bool` |
| `all` | `(List<a>, (a) -> Bool) -> Bool` |
| `find` | `(List<a>, (a) -> Bool) -> Option<a>` |
| `head` | `List<a> -> Option<a>` |
| `nth` | `(List<a>, Int) -> Option<a>` |
| `unique` | `List<String> -> List<String>` |
| `unique_by` | `(List<a>, (a) -> String) -> List<a>` |

`map` is recursive, not `par` — the module stays Pure.

### `hwfl/string`

| Fun | Signature |
|-----|-----------|
| `is_empty` | `String -> Bool` |
| `join_with` | `(List<String>, String) -> String` |
| `words` | `String -> List<String>` |
| `trim` | `String -> String` |
| `contains` | `(String, String) -> Bool` |
| `starts_with` | `(String, String) -> Bool` |
| `strip_suffix` | `(String, String) -> String` |

Prefer prelude `text.*` when a one-liner is enough. `join` is a keyword;
the stdlib name is `join_with`.

### `hwfl/option`

| Fun | Signature |
|-----|-----------|
| `is_some` | `Option<a> -> Bool` |
| `is_none` | `Option<a> -> Bool` |
| `map` | `(Option<a>, (a) -> b) -> Option<b>` |
| `and_then` | `(Option<a>, (a) -> Option<b>) -> Option<b>` |
| `or_else` | `(Option<a>, () -> Option<a>) -> Option<a>` |
| `unwrap_or` | `(Option<a>, a) -> a` |
| `to_list` | `Option<a> -> List<a>` |

### `hwfl/result`

| Fun | Signature |
|-----|-----------|
| `is_ok` | `Result<a, e> -> Bool` |
| `is_err` | `Result<a, e> -> Bool` |
| `map` | `(Result<a, e>, (a) -> b) -> Result<b, e>` |
| `map_err` | `(Result<a, e>, (e) -> g) -> Result<a, g>` |
| `and_then` | `(Result<a, e>, (a) -> Result<b, e>) -> Result<b, e>` |
| `unwrap_or` | `(Result<a, e>, a) -> a` |
| `to_option` | `Result<a, e> -> Option<a>` |

## A–Z

`&&` · `||` · `!=` · `==` · `<` · `<=` · `>` · `>=` · `*` · `+` · `-` · `/` ·
`@slug` · `$"…"` · `all` · `and_then` · `any` · `append` · `choice` ·
`confirm` · `contains` · `ctx.run` · `drop` · `exec.run` · `false` ·
`filter` · `find` · `flat_map` · `fold_left` · `fs.copy` · `fs.edit` ·
`fs.exists` · `fs.find` · `fs.grep` · `fs.list` · `fs.mkdir` · `fs.move` ·
`fs.patch` · `fs.read` · `fs.read_slice` · `fs.remove` · `fs.stat` ·
`fs.write` · `fun` · `head` · `human.ask` · `human.choice` ·
`human.confirm` · `if` · `is_empty` · `is_err` · `is_none` · `is_ok` ·
`is_some` · `join` · `join_with` · `json.encode` · `length` · `let` ·
`list.concat` · `list.length` · `llm.agent` · `llm.agent_object` ·
`llm.chat` · `llm.chat_messages` · `llm.object` · `map` · `map_err` ·
`match` · `mcp.call` · `mcp.tools` · `md.sections` · `meta.check_module` ·
`meta.check_project` · `meta.invoke` · `meta.list_runs` ·
`meta.read_snapshot` · `meta.read_spans` · `not` · `nth` · `obs.log` ·
`obs.span` · `or_else` · `par` · `reverse` · `schema` · `skill.discover` ·
`skill.load` · `starts_with` · `strip_suffix` · `take` · `text.contains` ·
`text.is_qname` · `text.metrics` · `text.normalize_token` ·
`text.similarity` · `text.split_sentences` · `text.starts_with` ·
`text.strip_suffix` · `text.trim` · `text.words` · `to_list` ·
`to_option` · `tool` · `trim` · `true` · `try` · `type` · `unique` ·
`unique_by` · `unwrap_or` · `words`
