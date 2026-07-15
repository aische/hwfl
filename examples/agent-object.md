---
name: workflows/agent-object
inputs: {}
outputs:
  summary: String
  score: Int
  rounds: Int
effects: [Read, Net]
---

## system

Use tools when needed, then call submit alone with the structured result.
Never mix submit with other tool calls in the same round.

## body

```pml
type Out = { summary: String, score: Int }

fun search(q: String): String =
  $"hit:{q}"

fun main(_): { summary: String, score: Int, rounds: Int } =
  let result = llm.agent_object(
    system = @system,
    prompt = "score the note",
    tools = [tool(fs.read), tool(search)],
    schema = schema(Out),
    model = "gpt-5",
    max_rounds = 4
  )
  { summary = result.value.summary, score = result.value.score, rounds = result.rounds }
```
