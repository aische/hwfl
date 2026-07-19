---
name: workflows/promote
inputs:
  env: String
  version: String
outputs:
  promoted: Bool
  message: String
effects: [Human]
examples:
  - name: staging
    inputs:
      env: staging
      version: "1.2.3"
---

## body

```hwfl
fun main(inputs: { env: String, version: String }): {
  promoted: Bool,
  message: String
} =
  let ok = confirm {
    title = $"Promote {inputs.version} to {inputs.env}?",
    detail = "Approve to continue; deny aborts."
  }
  if ok then
    { promoted = true, message = $"promoted {inputs.version} → {inputs.env}" }
  else
    { promoted = false, message = "aborted by operator" }
```
