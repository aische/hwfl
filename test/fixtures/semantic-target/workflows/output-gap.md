---
name: workflows/output-gap
inputs: {}
outputs:
    msg: String
effects: []
---

## schema Result

- msg: Short status string.
- report_path: Workspace-relative path of the written report.

## body

```hwfl
fun main(_): { msg: String } =
  { msg = "output-gap" }
```
