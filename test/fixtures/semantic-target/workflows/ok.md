---
name: workflows/ok
inputs: {}
outputs:
    msg: String
effects: []
---

## agent

You must call lib/search when needed. Prefer tools/helper for lookup.

## body

```hwfl
fun main(_): { msg: String } =
  { msg = "ok" }
```
