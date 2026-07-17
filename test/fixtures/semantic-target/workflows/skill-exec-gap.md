---
name: workflows/skill-exec-gap
inputs: {}
outputs:
    msg: String
effects: [Read, Net]
---

## system

Follow skills/recommend-exec before finishing. Prefer small edits.

## body

```hwfl
fun main(_): { msg: String } =
  let _ = @system
  { msg = "skill-exec-gap" }
```
