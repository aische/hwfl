---
name: workflows/main
inputs:
    xs: String
outputs:
    unique: String
    joined: String
effects: []
imports:
    - hwfl/list
    - hwfl/string
---

## body

```hwfl
fun main(inputs): { unique: String, joined: String } =
  let words = hwfl/string.words(inputs.xs)
  let uniq = hwfl/list.unique(words)
  { unique = hwfl/string.join_with(uniq, ","), joined = hwfl/string.join_with(words, " ") }
```
