---
name: workflows/agent-choice
inputs: {}
outputs:
  text: String
  rounds: Int
effects: [Human, Net]
---

## system

You help operators pick a deployment target. When you need a human decision,
call ask_user with a clear question and a short list of options. After the
human answers, reply with a one-line confirmation that includes their choice.

## body

```hwfl
fun ask_user(question: String, options: List<String>): String =
  human.choice({
    title = question,
    detail = "agent request",
    options = options
  })

fun main(_): { text: String, rounds: Int } =
  let result = llm.agent(
    system = @system,
    prompt = "Ask which environment to deploy to (staging, prod, or abort).",
    tools = [tool(ask_user)],
    model = "deepseek4flash",
    max_rounds = 4
  )
  { text = result.text, rounds = result.rounds }
```
