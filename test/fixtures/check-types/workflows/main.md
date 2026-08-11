---
name: workflows/main
inputs: {}
outputs:
  sum: Int
effects: []
imports:
  - types/main
  - lib/geom
---

## body

```hwfl
fun main(_): { sum: Int } =
  let p = lib/geom.add(lib/geom.origin(()), { x = 1, y = 2 })
  { sum = p.x + p.y }
```
