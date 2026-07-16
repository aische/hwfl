---
name: lib/search
inputs: {}
outputs:
    hit: String
effects: []
---

## overview

You must return a single hit string. Always prefer exact matches.

## body

```hwfl
fun main(_): { hit: String } =
  { hit = "x" }
```
