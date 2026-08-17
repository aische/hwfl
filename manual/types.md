# Types

The checker is bidirectional with value / let-polymorphism
(`List<a>`, `(a) -> b`). Effect polymorphism (`forall e. …`) is not
available — effects are inferred and checked against the module ceiling.

## Builtin types

| Type | Literal / intro | Notes |
|------|-----------------|-------|
| `Unit` | `()` | |
| `Bool` | `true` `false` | |
| `Int` | `0` `-12` | Arbitrary precision |
| `Float` | `1.5` | Must have a decimal point |
| `String` | `"…"` `"""…"""` `$"…"` | UTF-8 |
| `Bytes` | — | No coercion to/from `String` |
| `Json` | — | Untyped; prefer records at boundaries |
| `FileRef` | path string at a `FileRef` parameter | Runtime is a workspace-relative path |
| `List<T>` | `[e, …]` | Homogeneous |
| `{ f: T, … }` | `{ f = e, … }` | Structural records |
| `Option<T>` | `Some(e)` `None` | `None` needs a type context |
| `Result<T, E>` | `Ok(e)` `Err(e)` | |
| `Secret<T>` | — | Not interpolable; redacted in spans; not comparable |
| `Schema` | `schema(T)` | JSON Schema for structured LLM / MCP decode |
| `ToolSpec` | `tool(f)` | Agent tool registration |
| `Turn` | from `llm.agent` `history` | Opaque-ish transcript; do not construct by hand |
| `Error` | — | Primitive name reserved; catch uses `String` |

## Records

Type: `{ name: String, n: Int }`  
Value: `{ name = "x", n = 1 }` or pun `{ name, n }`.

Field access `e.n`. Missing field is a check error. Extra fields at a
known record type are a check error. Host ops with optional fields
(`detail?`, `overwrite?`) are special-cased — omit the field rather than
passing a dummy.

## Functions

```text
(T) -> U
(T) -[Read, Net]-> U
```

Multi-parameter `fun f(a: A, b: B): R` has domain `{ a: A, b: B }`.
Call positionally in declaration order or with names.

Annotations on `fun` / module are optional for locals; **top-level `fun`
return types are required**.

## Aliases

```hwfl
type Finding = { kind: String, path: String, detail: String }
```

Resolved during check. Cycles rejected. Shared shapes belong in
`types/*.md` (typically one `types/main`) and are imported into scope
unqualified.

No user type constructors (`type Pair<a> = …`) and no user sums
(`type Colour = Red | Blue`). Use records, `Option`, and `Result`.

## Option and Result

```hwfl
let a: Option<Int> = Some(1)
let b: Option<Int> = None

match a with
| None => 0
| Some(n) => n

let r: Result<Int, String> = Ok(1)
match r with
| Ok(n) => n
| Err(msg) => 0
```

`Some` / `Ok` / `Err` require a payload. Combinators:
[`hwfl/option`](library/stdlib.md), [`hwfl/result`](library/stdlib.md).

## FileRef and String

A string literal (or `String` value) may be passed where `FileRef` is
expected, and `==` may compare the two. This is **path coercibility**,
not general subtyping — a `String` field in a record does not silently
become `FileRef`.

Paths are workspace-relative. Absolute paths and `..` escape are sandbox
errors. See [fs](library/fs.md).

## Secret

`Secret<T>` cannot appear in `$"…{e}…"` (check error). Spans and
snapshots redact secrets. Do not put `Secret<_>` in skill `inputs` if the
skill should be agent-eligible.

## Schema reflection

`schema(T)` yields a JSON Schema used by `llm.object`,
`llm.agent_object`’s synthetic `submit` tool, and optional `mcp.call`
decoding. `Option` fields become optional JSON properties. Markdown
`## schema TypeName` sections with `- field: description` bullets attach
descriptions to that schema.

```markdown
## schema Result

- summary: One paragraph.
- ok: True when verification succeeded.
```

```hwfl
type Result = { summary: String, ok: Bool }
schema(Result)
```

## Interpolation rendering

Allowed: `Unit`, `Bool`, `Int`, `Float`, `String`, `FileRef`, `Json`,
and lists / options / results / records thereof. Structured values render
as canonical JSON. `Bytes` and `Secret<_>` are check errors.
`json.encode` uses the same renderability rule.

## Polymorphism

User and stdlib `fun`s may be polymorphic:

```hwfl
fun head(xs: List<a>): Option<a> =
  if list.length(xs) == 0 then None else Some(xs[0])
```

Effect sets are monomorphic. A function that calls `fs.read` always
requires `Read`; you cannot write `forall e. …`.
