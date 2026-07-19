---
name: workflows/choose
inputs: {}
outputs:
  env: String
  message: String
effects: [Human]
---

## body

```hwfl
fun main(_): { env: String, message: String } =
  let env = choice {
    title = "Deploy target?",
    detail = "Pick where to promote the build.",
    options = ["staging", "prod", "abort"]
  }
  if env == "abort" then
    { env = env, message = "aborted by operator" }
  else
    { env = env, message = $"deploying to {env}" }
```
