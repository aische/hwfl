---
name: lib/list
effects: []
---

## body

```pml
fun unique_by(xs: List<String>, i: Int, n: Int, seen: List<String>): List<String> =
  if i >= n then []
  else
    let x = xs[i]
    let rest = unique_by(xs, i + 1, n, seen)
    if contains(seen, x, 0, list.length(seen)) then rest
    else list.concat([x], rest)

fun contains(xs: List<String>, q: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == q then true
  else contains(xs, q, i + 1, n)
```
