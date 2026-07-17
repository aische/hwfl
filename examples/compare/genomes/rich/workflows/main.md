---
name: workflows/main
inputs:
  path: FileRef
outputs:
  title: String
  bullets: List<String>
  ok: Bool
effects: [Read, Net]
---

## system

Draft notes, then extract a short title and 2-4 factual bullets. No preamble.

## body

```hwfl
type Facts = { title: String, bullets: List<String> }

fun main(inputs): { title: String, bullets: List<String>, ok: Bool } =
  let contents = fs.read(inputs.path)
  let draft = llm.chat(
    system = @system,
    prompt = contents.text,
    model = "deepseek4flash"
  )
  let facts = llm.object(
    prompt = draft,
    schema = schema(Facts),
    model = "deepseek4flash"
  )
  { title = facts.title, bullets = facts.bullets, ok = true }
```
