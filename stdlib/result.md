---
name: hwfl/result
effects: []
---

# hwfl/result

Combinators for `Result<a, e>`.

## body

```hwfl
fun is_ok(r: Result<a, e>): Bool =
  match r with
  | Ok(_) => true
  | Err(_) => false

fun is_err(r: Result<a, e>): Bool =
  match r with
  | Ok(_) => false
  | Err(_) => true

fun map(r: Result<a, e>, f: (a) -> b): Result<b, e> =
  match r with
  | Ok(x) => Ok(f(x))
  | Err(e) => Err(e)

fun map_err(r: Result<a, e>, f: (e) -> g): Result<a, g> =
  match r with
  | Ok(x) => Ok(x)
  | Err(e) => Err(f(e))

fun and_then(r: Result<a, e>, f: (a) -> Result<b, e>): Result<b, e> =
  match r with
  | Ok(x) => f(x)
  | Err(e) => Err(e)

fun unwrap_or(r: Result<a, e>, d: a): a =
  match r with
  | Ok(x) => x
  | Err(_) => d

fun to_option(r: Result<a, e>): Option<a> =
  match r with
  | Ok(x) => Some(x)
  | Err(_) => None
```
