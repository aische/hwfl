# 03 — Types

## 1. Goals

- Catch interface mistakes before run
- Drive JSON Schema for `llm.object` / agent tools
- Stay approachable: no full dependent types

## 2. Type language

### 2.1 Base & structural

```text
Unit | Bool | Int | Float | String | Bytes | Json
FileRef
List<T>
{ f1: T1, f2: T2, … }          -- record
Optional<T> | Option<T>        -- pick one spelling in M0; recommend Option
Result<T, E>
```

### 2.2 Nominal & aliases

```text
type Finding = { kind: String, path: String, detail: String }
```

Aliases resolve during check; cycles rejected.

### 2.3 Sums (v0)

```text
type Force = Declarative | Directive | Question
type Gate = Redundancy({ … }) | Divergence({ … })
```

Or closed enums of strings where enough — prefer real sums for agent I/O.

### 2.4 Function types

```text
(T1, T2) -> U
{ a: T, b: U } -> R            -- preferred named record args for public APIs
```

Effect annotations on function types:

```text
(T) -[Read, Net]-> U
```

Surface may put effects on `fun` / module and infer for locals.

### 2.5 Special types

| Type | Role |
|------|------|
| `Json` | Untyped JSON; prefer structured records at boundaries |
| `Secret<T>` | Non-interpolable; redacted in spans |
| `Schema` | Reflected type for LLM structured output |
| `ModuleRef` / `FunRef` | **[defer]** first-class refs |

## 3. Checking discipline

- **Bidirectional** or HM-style for the kernel — implementer’s choice if
  tests pass the example suite.
- Module `inputs`/`outputs` are **checked** against `main`.
- Host ops have fixed signatures in a prelude.
- Import paths resolve to known exports.

### 3.1 Interpolation rendering

Same policy as hwfi: statically known renderability. `Bytes` and
`Secret<_>` in interpolations are check errors. Structured values render
as canonical JSON.

## 4. Schema reflection

`schema(T)` (compile-time / check-time operator) yields a JSON Schema
value used by `llm.object` and agent tool registration. At runtime the
machine evaluates it to `VSchema` (pure eval still traps — host path only).

Rules:

- Records → `object` with `required` / `properties`
- Lists → `array`
- Sums → `oneOf` / discriminator (document chosen encoding)
- `Json` → free-form object/any
- Functions / closures → check error

## 5. Subtyping

v0: **width subtyping for records** on function arguments (extra fields
OK when passing to a narrower parameter) — optional; if costly, require
exactness and provide `pick` in stdlib.

No depth subtyping variance complexity beyond `Option`/`List` covariance
if easy; otherwise invariant.

### 5.1 Path coercibility (`String` ≅ `FileRef`)

Dedicated rule (not general subtyping): a `String` path literal may be
used where `FileRef` is expected, and `==` / `!=` may compare `String` with
`FileRef`. Runtime `FileRef` is a workspace path string. This does **not**
make `String` and `FileRef` interchangeable elsewhere (e.g. no `String` `+`).

### 5.2 Overloaded operators

Applications of `+ - * /`, `== !=`, and ordered comparisons are overloaded
by operand sort (`Pml.Check.Overload`):

| Class | Allowed same-sort operands | Result |
|-------|------------------------------|--------|
| arith | `Int` or `Float` (no mix, no `String`) | same numeric type |
| eq | comparable bases; structural `List`/`Record` of comparables; path rule | `Bool` |
| ord | `Int` \| `Float` \| `String` \| `FileRef` | `Bool` |

Bare overloaded operators (not applied) are check errors.

## 6. Null vs Option

Interop with JSON `null`:

- Prefer decoding into `Option`
- Bare `null` literal only where type is `Json` or `Option<T>`

Do not silently treat missing record fields as null unless declared
`Option`.
