---
name: workflows/obs-span
inputs: {}
outputs:
  n: Int
  label: String
effects: []
---

## body

```pml
fun main(_): { n: Int, label: String } =
  let clustered = obs.span("cluster")(fun () =>
    { n = 3, label = "ok" }
  )
  clustered
```
