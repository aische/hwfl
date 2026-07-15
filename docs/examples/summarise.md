# Example: summarise (informative)

Illustrative module for the greenfield repo’s `examples/hello`-class demo.
Not executable until the engine exists.

````markdown
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
    model = "gpt-5"
  )
  { summary }
```
````

**Expected spans:** `module:workflows/summarise` → `fs.read` → `llm.chat` → return.

**Snapshot points:** after `fs.read`; after `llm.chat`; completed.
