# 02 — Language (kernel)

The kernel is a **small, expression-oriented, typed ML**. It is the only
computation substrate. Markdown does not encode control flow outside
fences.

Grammar sketch: [11-grammar.ebnf](11-grammar.ebnf).

## 1. Design goals

- Enough language that libraries replace micro-host-ops
- Serializable closures restricted: free vars known; no exotic mutable captures
- Obvious elaboration to a CEK / frame machine

## 2. Lexical

- Comments: `--` to end of line; nested `{- -}` **[defer]** → v0 line comments only
- Identifiers: `[a-z_][a-zA-Z0-9_]*` for values; types `[A-Z][a-zA-Z0-9_]*`
- Keywords (reserved):  
  `let`, `in`, `fun`, `type`, `match`, `with`, `if`, `then`, `else`,  
  `par`, `for`, `in` (reuse), `join`, `task`, `try`, `catch`,  
  `confirm`, `true`, `false`, `null` (or prefer `None` — pick one in M0)

**Decision for v0:** use `null` only as JSON interop; prefer `Option` /
`Result` in surface code. Literal `true`/`false` stay.

## 3. Values (runtime)

| Value | Notes |
|-------|-------|
| Unit `()` | |
| Bool | |
| Int | arbitrary precision OK; document fixnum **[defer]** |
| Float | IEEE-ish; exact JSON number rules in host |
| String | UTF-8 |
| Bytes | no implicit string coercion |
| List | homogeneous at type level |
| Record | ordered fields for display; equal by name |
| Variant / sum | `Tag` or `Tag(payload)` |
| Closure | fun + env (serialised at snapshot only if live on stack) |
| HostRef | opaque (FileRef, etc.) |

## 4. Expressions

### 4.1 Core

- Literals, lists `[e,…]`, records `{ f = e, … }`
- Field access `e.f`, index `e[i]` (lists)
- `let x = e1 in e2` / sequential `let` blocks
- `fun (x: T): U = e` and multi-arg / record-arg sugar
- Application `e(e,…)` / named args for host ops and exported funs
- `if e then e else e`
- `match e with | pat => e | …`
- String interpolation `$"…{e}…"` (typed render rules like hwfi §3.2.1)
- Section ref `@slug`
- Qualified name `lib/text.trim` after import elaboration

### 4.2 Control sugar (elaborates to core + host)

```text
par(max = N) for x in xs { e }     -- structured parallel map
join { task { e1 }; task { e2 } }  -- fixed arity join
confirm { title = …; detail = … } -- Human effect
try e catch (err) => e2            -- catchable failures
```

These are **not** pure: they interact with the frame machine
([06-runtime.md](06-runtime.md)).

### 4.3 Deliberately omitted (v0)

- Mutable `ref` / assignment (or only behind `State` effect **[defer]**)
- Classes / prototypes / `this`
- Async/await keywords (use `par`/`join`)
- Macros / Template Haskell-like reify beyond `schema(T)`
- Higher-kinded user types beyond `List`, `Option`, `Result`, `Map` **[defer Map]**

## 5. Patterns

```text
_
x
literal
{ f = p, … }
[p, …] / list cons **[defer cons]** — v0: fixed list patterns + `as`
Tag / Tag(p)
```

## 6. Top-level declarations

```text
type Name = TypeExpr
fun name(args): Ret = body
```

Mutual recursion: `fun` group **[defer]`** — v0 allow `let rec` for local
only; top-level mutual recursion optional if easy.

## 7. Evaluation order

- Call-by-value
- Record fields left-to-right
- List elements left-to-right
- `par` iterations: concurrent up to `max`, **result list order = input order**

## 8. Errors

- **Check errors** — static; abort before run
- **Trap errors** — panic/invariant (bug); fail run
- **Catchable errors** — host failures / `fail` / explicit `Error` throw;
  recoverable with `try`/`catch` or `Result`

Secret and Bytes misuse in string interpolation are **check errors**.

## 9. Serialization note

At snapshot time the machine stores values on the stack/heap with a
stable JSON codec. Closures must either:

- be reconstructed from module code + free-value env, or  
- be disallowed across host boundaries (force top-level function refs)

**v0 rule:** across host/par boundaries prefer **top-level function
qnames** or fully-applied closed values. Nested closures capturing large
envs may be rejected by check until a robust codec exists.
