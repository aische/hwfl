---
name: workflows/main
inputs: {}
outputs:
  mapped: List<Int>
  filtered: List<Int>
  uniq: List<String>
  label: String
effects: []
imports:
  - hwfl/list
  - hwfl/option
  - hwfl/string
---

## body

```hwfl
fun main(_): {
  mapped: List<Int>,
  filtered: List<Int>,
  uniq: List<String>,
  label: String
} =
  let xs = [1, 2, 3, 4]
  let mapped = hwfl/list.map(xs, fun (n: Int): Int => n * 10)
  let filtered = hwfl/list.filter(xs, fun (n: Int): Bool => n > 2)
  let uniq = hwfl/list.unique(["a", "b", "a", "c"])
  let head = hwfl/option.unwrap_or(hwfl/list.head(mapped), 0)
  {
    mapped = mapped,
    filtered = filtered,
    uniq = uniq,
    label = hwfl/string.join_with([$"head={head}"], "")
  }
```
