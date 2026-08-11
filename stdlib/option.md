---
name: hwfl/option
effects: []
---

# hwfl/option

Combinators for `Option<a>`.

## body

```hwfl
fun is_some(o: Option<a>): Bool =
  match o with
  | None => false
  | Some(_) => true

fun is_none(o: Option<a>): Bool =
  match o with
  | None => true
  | Some(_) => false

fun map(o: Option<a>, f: (a) -> b): Option<b> =
  match o with
  | None => None
  | Some(x) => Some(f(x))

fun and_then(o: Option<a>, f: (a) -> Option<b>): Option<b> =
  match o with
  | None => None
  | Some(x) => f(x)

fun or_else(o: Option<a>, f: Unit -> Option<a>): Option<a> =
  match o with
  | None => f()
  | Some(x) => Some(x)

fun unwrap_or(o: Option<a>, d: a): a =
  match o with
  | None => d
  | Some(x) => x

fun to_list(o: Option<a>): List<a> =
  match o with
  | None => []
  | Some(x) => [x]
```
