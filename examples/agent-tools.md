---
name: workflows/agent-tools
inputs: {}
outputs:
    text: String
    rounds: Int
effects: [Read, Net]
---

## system

You use tools when needed. Prefer fs.read for file contents and search for
lookup queries.

## body

```hwfl
fun search(q: String): String =
  $"hit:{q}"

fun main(_): { text: String, rounds: Int } =
  let result = llm.agent(
    system = @system,
    prompt = "find note",
    tools = [tool(fs.read), tool(search)],
    model = "gpt-5",
    max_rounds = 4
  )
  { text = result.text, rounds = result.rounds }
```
