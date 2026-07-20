---
name: workflows/main
inputs:
    value: Int
outputs:
    summary: String
effects: []
imports:
    - workflows/inner
---

## About

Demonstrates E11: calling a same-project entry module as a function.
`workflows/inner` is imported and called as `workflows/inner(...)`;
the callee runs in the same run/workspace under a nested `FrInvoke` frame.

```hwfl
fun main(inputs): { summary: String } =
  let r1 = workflows/inner({ x = inputs.value, label = "first" })
  let r2 = workflows/inner({ x = inputs.value + 1, label = "second" })
  { summary = $"{r1.result} / {r2.result}" }
```
