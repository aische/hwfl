---
name: workflows/inner
inputs:
    x: Int
    label: String
outputs:
    result: String
effects: []
---

## About

A simple inner module that formats a labelled integer as a string.
Called by `workflows/main` via `workflows/inner(inputs)` — E11 same-project
entry call.

```hwfl
fun main(inputs): { result: String } =
  let msg = $"{inputs.label}: {inputs.x}"
  { result = msg }
```
