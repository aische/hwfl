# Syntax

Expression-oriented ML. The fence body is declarations (`type`, `fun`)
followed by an optional trailing expression. Entry modules use
`fun main`.

Every construct below is a copy-pasteable form plus the rules that bite
when writing. Full signatures: [cheatsheet](cheatsheet.md).

## Module envelope

A module is YAML frontmatter, markdown prose, and **exactly one**
` ```hwfl ` fence (instruction skills are prose-only — [projects](project.md)).

````markdown
---
name: workflows/main
inputs:
  n: Int
outputs:
  doubled: Int
effects: []
---

## body

```hwfl
fun main(inputs): { doubled: Int } =
  { doubled = inputs.n * 2 }
```
````

- `name` must equal the file’s qname (`workflows/main.md` → `workflows/main`).
- `fun main` is required when `inputs` or `outputs` are non-empty.
- Empty inputs: `inputs: {}` and `fun main(_): { … } =`.
- Frontmatter `inputs` / `outputs` fill in `main`’s parameter and return
  types when you omit them.

## Comments and names

```hwfl
-- line comment to end of line
```

No block comments. Identifiers: `[a-z_][a-zA-Z0-9_]*` for values,
`[A-Z][a-zA-Z0-9_]*` for types and tags (`Some`, `Ok`).

Reserved (cannot be identifiers): `let`, `in`, `fun`, `type`, `match`,
`with`, `if`, `then`, `else`, `par`, `for`, `join`, `task`, `try`,
`catch`, `confirm`, `choice`, `true`, `false`.

Field names after `.` may be reserved: `human.confirm` parses.

Tight `lib/text` is a qname. Spaced `a / b` is division.

## Literals

| Syntax | Type |
|--------|------|
| `()` | `Unit` |
| `true` `false` | `Bool` |
| `0` `-3` | `Int` |
| `1.0` `3.14` | `Float` |
| `"hello"` | `String` |
| `"line\n"` | escapes: `\"` `\\` `\n` `\t` `\r` |
| `"""multi-line"""` | `String` (ends at the next `"""`) |
| `[1, 2, 3]` | `List<Int>` |
| `[]` | `List<T>` — needs a type context |
| `{ x = 1, y = "a" }` | record value |

There is no `null` literal. Use `None` / `Option`. There is no `Bytes`
literal.

## `let`

```hwfl
let x = 1 in x + 2

let y: Int = 1 in y
```

Sequential `let` (no `in`) is legal when the **body starts on a later
line**. Same-line `let x = a b` is not silently `let x = a in b`.

```hwfl
fun main(_): { n: Int } =
  let a = 1
  let b = a + 1
  { n = b }
```

`let` is not recursive. Recursive functions must be **top-level** `fun`
declarations (the name is in scope in every top-level body).

A `let`-bound lambda can be used at more than one type:

```hwfl
let id = fun (x) => x
```

## `fun`

**Top-level** (return type required):

```hwfl
fun add(x: Int, y: Int): Int = x + y

fun greet(name: String): String =
  $"hello {name}"
```

**Lambda** (`=>` or `=`):

```hwfl
fun (n: Int): Int => n * 2
fun () => 1
```

Zero parameters is a `Unit` thunk: call with `f()`. A single unannotated
parameter is also `Unit` (`fun main(_)` with empty `inputs`).

Two or more parameters become a **record domain**. These are equivalent:

```hwfl
add(1, 2)
add(x = 1, y = 2)
```

One typed parameter stays a single-argument function: `greet("Ada")`.

Host ops and public APIs prefer **named** arguments
(`fs.write(path = "a.txt", text = "hi")`). A single record value also
works: `fs.write({ path = "a.txt", text = "hi" })`.

Top-level `fun`s in one module may call each other (including recursion).
Local `let f = fun …` **cannot** recurse — `f` is not in scope in its own
body.

## Application, fields, index

```hwfl
f(x)
f(a, b)
f(name = "x", n = 1)
e.field
xs[i]          -- i : Int, xs : List<T>
```

There is no optional chaining and no string index.

## Records

**Type** uses `:` · **value** uses `=` · **pun** repeats a bound name.

```hwfl
type Point = { x: Int, y: Int }

let p = { x = 1, y = 2 }
let x = 1
let y = 2
{ x, y }              -- shorthand for { x = x, y = y }
p.x
```

Duplicate fields are a check error. Records equal by field name, not
declaration order.

## Lists

```hwfl
let xs = [1, 2, 3]
list.length(xs)       -- 3
list.concat(xs, [4])  -- [1, 2, 3, 4]
xs[0]                 -- 1
```

Homogeneous. Out-of-range index is a runtime trap (not `Option` — use
`hwfl/list.nth`). For `map` / `filter` / `head`, import
[`hwfl/list`](library/stdlib.md).

No cons pattern (`[x, ...rest]`). Match fixed lengths or index.

## `if`

```hwfl
if n > 0 then n else 0
```

`else` is required. Both branches must have the same type.
`&&` / `||` short-circuit.

## `match`

```hwfl
match xs with
| [] => 0
| [x] => x
| _ => -1

match opt with
| None => 0
| Some(n) => n
```

Each arm starts with `|`. Patterns:

| Pattern | Matches |
|---------|---------|
| `_` | Anything (unbound) |
| `x` | Anything, bind `x` |
| `true` / `1` / `"a"` / `()` | Literal |
| `{ f = p, … }` | Record fields (listed fields must be present) |
| `[p, …]` | Exact-length list |
| `Tag` / `Tag(p)` | `None`, `Some(p)`, `Ok(p)`, `Err(p)` |

User-defined sum types are not in the language. Only `Option` and
`Result` tags.

`None` has no principal type — annotate or put it in a context:

```hwfl
let empty: Option<Int> = None
```

## Interpolation and sections

```hwfl
$"hello {name}"
$"count = {n}\n"
```

Escapes inside `$"…"`: `\"` `\\` `\{` `\n` `\t`. Interpolated expressions
must be renderable: `Unit`, `Bool`, `Int`, `Float`, `String`, `FileRef`,
`Json`, and lists / options / results / records of those. **Not**
`Secret<_>`, functions, or `Bytes`. Structured values render as JSON.

`@slug` is the body of a markdown heading. Slugify: lowercase, spaces to
`-`, keep `[a-z0-9-]`. H2 and H3 are indexed. Empty or duplicate slugs
are load errors.

```markdown
## system

You are brief.

## body
```

```hwfl
llm.chat(system = @system, prompt = "Hi", model = "deepseek4flash")
```

## Operators

Same-sort arithmetic only (`Int` with `Int`, `Float` with `Float`).
**No** `String` `+` — use interpolation or `hwfl/string.join_with`.

```hwfl
1 + 2
3.0 * 2.0
"abc" == "abc"
"a.txt" == someFileRef     -- path coercibility
true && false
not true
```

Comparison `<` `<=` `>` `>=` on `Int`, `Float`, `String`, `FileRef`.
Equality also on `Unit`, `Bool`, `List<T>`, and records when the contents
are comparable. Secrets cannot be compared.

## `type`

```hwfl
type Finding = {
  kind: String,
  path: String,
  detail: String
}
```

Aliases only: `type Name = TypeExpr`. No user type constructors
(`Pair<a>`) and no user sums (`Red | Blue`). Cycles are rejected. Importing
`types/main` brings those aliases into scope **unqualified** (`Finding`,
not `types/main.Finding`). Duplicate alias names across imports are
errors.

## `schema` and `tool`

```hwfl
type Out = { summary: String, score: Int }

schema(Out)           -- Schema (check-time reflection)
tool(fs.read)         -- ToolSpec
tool(myFun)           -- ToolSpec from a top-level fun
```

`schema(T)` is a type argument, not a value call. Used by `llm.object`,
`llm.agent_object`, and optional `mcp.call` decoding.

`tool(f)` accepts a host op or a function. Inside an agent the model sees
sanitised names: `fs.read` → `fs_read`, `lib/foo.bar` → `lib_foo_bar`.

## `try` / `catch`

```hwfl
try fs.read("missing.txt").text catch (err) => err
```

`err` is `String`. Catchable: missing files, provider failures, sandbox
errors. Not catchable: type/check errors, out-of-range index, and resume
refused after a code change.

The handler must have the same type as the `try` body.

## `par` and `join`

```hwfl
par(max = 4) for p in paths {
  fs.read(p).text
}

join {
  task { fs.read("a.txt").text }
  task { fs.read("b.txt").text }
}
```

Result **order matches input order**. `par` returns `List` of body
results. `join` returns `List` of the task results (same type). Tasks are
written one after another — no commas or semicolons between them.

Options: `max = N` caps active branches (default **4**). On a branch
failure the pool fails (the result type is always `List` of the body
type).

Requires effect `Parallel`. Branches do not run blocking host calls at
the same time.

`confirm` / `choice` / `human.ask` inside `par` **freezes the pool**.
Completed iterations are not re-run on resume. Resolve the gate with the
CLI, then continue.

## `confirm` and `choice`

Sugar for `human.confirm` / `human.choice`. The record may follow without
extra parentheses:

```hwfl
let ok = confirm {
  title = "Ship it?",
  detail = summary
}

let env = choice {
  title = "Deploy target?",
  options = ["staging", "prod", "abort"]
}
```

`human.ask` has no keyword sugar. Effect `Human`. See
[human](library/human.md).

## Evaluation

Call-by-value. Record fields and list elements left-to-right.

## Not in the language

- Mutation, `ref`, assignment
- `String` concatenation with `+`
- List cons patterns, `...rest`
- User-defined variants (`A | B`)
- `null` (JSON interop only, not surface syntax)
- `async` / `await` (use `par` / `join`)
- Macros, `Map<K,V>`
- Local recursive `let`
- Bare overloaded operators
- Reading process environment variables from the script
