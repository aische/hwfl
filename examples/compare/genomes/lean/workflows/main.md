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

Extract a short title and 2-4 factual bullets from the article. No preamble.

## body

```hwfl
type Facts = { title: String, bullets: List<String> }

fun main(inputs): { title: String, bullets: List<String>, ok: Bool } =
  let contents = fs.read(inputs.path)
  let facts = llm.object(
    prompt = contents.text,
    schema = schema(Facts),
    model = "deepseek4flash"
  )
  { title = facts.title, bullets = facts.bullets, ok = true }
```
