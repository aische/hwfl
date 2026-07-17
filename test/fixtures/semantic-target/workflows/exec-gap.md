---
name: workflows/exec-gap
inputs: {}
outputs:
    msg: String
effects: [Read, Net]
---

## system

You must verify changes with exec.run using the skill's recommended commands.
Do not skip verification after edits.

## body

```hwfl
fun main(_): { msg: String } =
  let _ = @system
  { msg = "exec-gap" }
```
