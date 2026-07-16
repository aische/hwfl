---
name: workflows/summarise
inputs:
  path: FileRef
outputs:
  summary: String
effects: [Read, Net]
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## body

```pml
fun main(inputs): { summary: String } =
  let contents = fs.read(inputs.path)
  let summary = llm.chat(
    system = @system,
    prompt = $"Summarise the following:\n\n{contents.text}",
    model = "deepseek4flash"
  )
  { summary }
```
