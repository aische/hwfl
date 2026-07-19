# Example: summarise (informative)

Reference contract for the summarise workflow (E04). Runnable via
`examples/summarise.md` with `hwfl run` and a mock or real provider.

````markdown
---
name: workflows/summarise
inputs:
    path: FileRef
outputs:
    summary: String
effects: [Read, Net]
examples:
  - name: note
    inputs:
      path: note.md
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## body

```hwfl
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
