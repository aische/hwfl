---
name: hwfl/list
effects: []
---

# hwfl/list

Polymorphic list helpers over prelude `list.length` / `list.concat`.
`map` is recursive (not `par`) so the module stays Pure.

## body

```hwfl
fun is_empty(xs: List<a>): Bool =
  list.length(xs) == 0

fun length(xs: List<a>): Int =
  list.length(xs)

fun append(xs: List<a>, ys: List<a>): List<a> =
  list.concat(xs, ys)

fun map(xs: List<a>, f: (a) -> b): List<b> =
  map_go(xs, f, 0, list.length(xs))

fun map_go(xs: List<a>, f: (a) -> b, i: Int, n: Int): List<b> =
  if i >= n then []
  else list.concat([f(xs[i])], map_go(xs, f, i + 1, n))

fun filter(xs: List<a>, pred: (a) -> Bool): List<a> =
  filter_go(xs, pred, 0, list.length(xs))

fun filter_go(xs: List<a>, pred: (a) -> Bool, i: Int, n: Int): List<a> =
  if i >= n then []
  else
    let x = xs[i]
    let rest = filter_go(xs, pred, i + 1, n)
    if pred(x) then list.concat([x], rest) else rest

fun flat_map(xs: List<a>, f: (a) -> List<b>): List<b> =
  flat_map_go(xs, f, 0, list.length(xs))

fun flat_map_go(xs: List<a>, f: (a) -> List<b>, i: Int, n: Int): List<b> =
  if i >= n then []
  else list.concat(f(xs[i]), flat_map_go(xs, f, i + 1, n))

fun fold_left(xs: List<a>, acc: b, f: (b) -> (a) -> b): b =
  fold_left_go(xs, acc, f, 0, list.length(xs))

fun fold_left_go(xs: List<a>, acc: b, f: (b) -> (a) -> b, i: Int, n: Int): b =
  if i >= n then acc
  else fold_left_go(xs, f(acc)(xs[i]), f, i + 1, n)

fun take(xs: List<a>, k: Int): List<a> =
  take_go(xs, k, 0, list.length(xs))

fun take_go(xs: List<a>, k: Int, i: Int, n: Int): List<a> =
  if i >= k || i >= n then []
  else list.concat([xs[i]], take_go(xs, k, i + 1, n))

fun drop(xs: List<a>, k: Int): List<a> =
  drop_go(xs, k, 0, list.length(xs))

fun drop_go(xs: List<a>, k: Int, i: Int, n: Int): List<a> =
  if i >= n then []
  else if i < k then drop_go(xs, k, i + 1, n)
  else list.concat([xs[i]], drop_go(xs, k, i + 1, n))

fun reverse(xs: List<a>): List<a> =
  reverse_go(xs, 0, list.length(xs), [])

fun reverse_go(xs: List<a>, i: Int, n: Int, acc: List<a>): List<a> =
  if i >= n then acc
  else reverse_go(xs, i + 1, n, list.concat([xs[i]], acc))

fun any(xs: List<a>, pred: (a) -> Bool): Bool =
  any_go(xs, pred, 0, list.length(xs))

fun any_go(xs: List<a>, pred: (a) -> Bool, i: Int, n: Int): Bool =
  if i >= n then false
  else if pred(xs[i]) then true
  else any_go(xs, pred, i + 1, n)

fun all(xs: List<a>, pred: (a) -> Bool): Bool =
  all_go(xs, pred, 0, list.length(xs))

fun all_go(xs: List<a>, pred: (a) -> Bool, i: Int, n: Int): Bool =
  if i >= n then true
  else if pred(xs[i]) then all_go(xs, pred, i + 1, n)
  else false

fun find(xs: List<a>, pred: (a) -> Bool): Option<a> =
  find_go(xs, pred, 0, list.length(xs))

fun find_go(xs: List<a>, pred: (a) -> Bool, i: Int, n: Int): Option<a> =
  if i >= n then None
  else if pred(xs[i]) then Some(xs[i])
  else find_go(xs, pred, i + 1, n)

fun head(xs: List<a>): Option<a> =
  if list.length(xs) == 0 then None else Some(xs[0])

fun nth(xs: List<a>, i: Int): Option<a> =
  if i < 0 || i >= list.length(xs) then None else Some(xs[i])

fun unique(xs: List<String>): List<String> =
  unique_go(xs, 0, list.length(xs), [])

fun unique_go(xs: List<String>, i: Int, n: Int, seen: List<String>): List<String> =
  if i >= n then seen
  else
    let x = xs[i]
    if contains_string(seen, x, 0, list.length(seen)) then
      unique_go(xs, i + 1, n, seen)
    else
      unique_go(xs, i + 1, n, list.concat(seen, [x]))

fun contains_string(xs: List<String>, q: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == q then true
  else contains_string(xs, q, i + 1, n)

fun unique_by(xs: List<a>, key: (a) -> String): List<a> =
  unique_by_go(xs, key, 0, list.length(xs), [], [])

fun unique_by_go(
  xs: List<a>,
  key: (a) -> String,
  i: Int,
  n: Int,
  seen: List<String>,
  acc: List<a>
): List<a> =
  if i >= n then acc
  else
    let x = xs[i]
    let k = key(x)
    if contains_string(seen, k, 0, list.length(seen)) then
      unique_by_go(xs, key, i + 1, n, seen, acc)
    else
      unique_by_go(xs, key, i + 1, n, list.concat(seen, [k]), list.concat(acc, [x]))
```
