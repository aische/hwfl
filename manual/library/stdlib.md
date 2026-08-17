# Stdlib (`hwfl/*`)

Shipped markdown modules. Import them; they are not prelude.

```yaml
imports:
  - hwfl/list
  - hwfl/option
  - hwfl/string
  - hwfl/result
```

```hwfl
hwfl/list.map(xs, fun (n: Int): Int => n * 10)
hwfl/option.unwrap_or(hwfl/list.head(xs), 0)
hwfl/string.join_with(["a", "b"], ",")
```

Pack root: `HWFL_STDLIB` if set, else the stdlib shipped with the
install, else a `stdlib/` found from the current directory. Projects
must not claim qnames under `hwfl/`.

Helpers named `*_go` are internal. Call the public `fun`s below.
All four modules are Pure (`effects: []`).

## `hwfl/list`

Polymorphic except `unique` (`List<String>`). `map` is recursive, not
`par`.

| Fun | Signature |
|-----|-----------|
| `is_empty` | `(xs: List<a>) -> Bool` |
| `length` | `(xs: List<a>) -> Int` |
| `append` | `(xs: List<a>, ys: List<a>) -> List<a>` |
| `map` | `(xs: List<a>, f: (a) -> b) -> List<b>` |
| `filter` | `(xs: List<a>, pred: (a) -> Bool) -> List<a>` |
| `flat_map` | `(xs: List<a>, f: (a) -> List<b>) -> List<b>` |
| `fold_left` | `(xs: List<a>, acc: b, f: (b) -> (a) -> b) -> b` |
| `take` | `(xs: List<a>, k: Int) -> List<a>` |
| `drop` | `(xs: List<a>, k: Int) -> List<a>` |
| `reverse` | `(xs: List<a>) -> List<a>` |
| `any` | `(xs: List<a>, pred: (a) -> Bool) -> Bool` |
| `all` | `(xs: List<a>, pred: (a) -> Bool) -> Bool` |
| `find` | `(xs: List<a>, pred: (a) -> Bool) -> Option<a>` |
| `head` | `(xs: List<a>) -> Option<a>` |
| `nth` | `(xs: List<a>, i: Int) -> Option<a>` |
| `unique` | `(xs: List<String>) -> List<String>` |
| `unique_by` | `(xs: List<a>, key: (a) -> String) -> List<a>` |

```hwfl
let xs = [1, 2, 3, 4]
let mapped = hwfl/list.map(xs, fun (n: Int): Int => n * 10)
let filtered = hwfl/list.filter(xs, fun (n: Int): Bool => n > 2)
let uniq = hwfl/list.unique(["a", "b", "a"])
```

`fold_left`’s combiner is curried: `fun (acc: b): (a) -> b => …`.

## `hwfl/string`

Thin wrappers over prelude `text.*` plus `join_with`. Prefer `text.trim`
directly when that is all you need. `join` is a kernel keyword.

| Fun | Signature |
|-----|-----------|
| `is_empty` | `(s: String) -> Bool` |
| `join_with` | `(parts: List<String>, sep: String) -> String` |
| `words` | `(s: String) -> List<String>` |
| `trim` | `(s: String) -> String` |
| `contains` | `(haystack: String, needle: String) -> Bool` |
| `starts_with` | `(s: String, prefix: String) -> Bool` |
| `strip_suffix` | `(s: String, suffix: String) -> String` |

## `hwfl/option`

| Fun | Signature |
|-----|-----------|
| `is_some` | `(o: Option<a>) -> Bool` |
| `is_none` | `(o: Option<a>) -> Bool` |
| `map` | `(o: Option<a>, f: (a) -> b) -> Option<b>` |
| `and_then` | `(o: Option<a>, f: (a) -> Option<b>) -> Option<b>` |
| `or_else` | `(o: Option<a>, f: Unit -> Option<a>) -> Option<a>` |
| `unwrap_or` | `(o: Option<a>, d: a) -> a` |
| `to_list` | `(o: Option<a>) -> List<a>` |

`or_else` takes a **thunk** `fun () => …`.

## `hwfl/result`

| Fun | Signature |
|-----|-----------|
| `is_ok` | `(r: Result<a, e>) -> Bool` |
| `is_err` | `(r: Result<a, e>) -> Bool` |
| `map` | `(r: Result<a, e>, f: (a) -> b) -> Result<b, e>` |
| `map_err` | `(r: Result<a, e>, f: (e) -> g) -> Result<a, g>` |
| `and_then` | `(r: Result<a, e>, f: (a) -> Result<b, e>) -> Result<b, e>` |
| `unwrap_or` | `(r: Result<a, e>, d: a) -> a` |
| `to_option` | `(r: Result<a, e>) -> Option<a>` |
