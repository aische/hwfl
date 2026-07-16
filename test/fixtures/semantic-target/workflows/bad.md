---
name: workflows/bad
inputs: {}
outputs:
    msg: String
effects: []
---

## notes

Mentions workflows/missing and tools/ghost which do not exist.

## body

```hwfl
fun main(_): { msg: String } =
  { msg = 1 }
```
