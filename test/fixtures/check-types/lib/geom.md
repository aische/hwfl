---
name: lib/geom
effects: []
imports:
  - types/main
---

## body

```hwfl
fun origin(_: Unit): Point = { x = 0, y = 0 }

fun add(a: Point, b: Point): Point =
  { x = a.x + b.x, y = a.y + b.y }
```
