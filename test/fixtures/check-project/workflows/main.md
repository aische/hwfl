---
name: workflows/main
inputs:
  xs: String
outputs:
  unique: String
effects: []
imports:
  - lib/list
---

## body

```pml
fun split_words(s: String): List<String> =
  text.words(s)

fun main(inputs): { unique: String } =
  let words = split_words(inputs.xs)
  let n = list.length(words)
  let _uniq = lib/list.unique_by(words, 0, n, [])
  { unique = "ok" }
```
