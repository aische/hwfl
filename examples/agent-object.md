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

## schema Out

- summary: One-sentence summary of the scored content.
- score: Integer score from 1 (poor) to 10 (excellent).

## body

```hwfl
type Out = { summary: String, score: Int }

fun search(q: String): String =
  $"hit:{q}"

fun main(_): { summary: String, score: Int, rounds: Int } =
  let result = llm.agent_object(
    system = @system,
    prompt = "score the note",
    tools = [tool(fs.read), tool(search)],
    schema = schema(Out),
    model = "deepseek4flash",
    max_rounds = 10
  )
  { summary = result.value.summary, score = result.value.score, rounds = result.rounds }
```
