# Example: parallel confirm (informative)

````markdown
---
name: workflows/install-check
inputs:
  packages: List<String>
outputs:
  results: List<{ name: String, ok: Bool }>
effects: [Exec, Parallel, Human]
---

## body

```hwfl
fun main(inputs): { results: List<{ name: String, ok: Bool }> } =
  let results =
    par(max = 2) for name in inputs.packages {
      let ok = human.confirm({
        title = $"Install {name}?",
        detail = name
      })
      if ok then
        let _ = exec.run(program = "echo", args = [name], stdin = "")
        { name, ok = true }
      else
        { name, ok = false }
    }
  { results }
```
````

**Contract:** any `human.confirm` inside `par` freezes the pool; completed
iterations are not re-run on resume.
