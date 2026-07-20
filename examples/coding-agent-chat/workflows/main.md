---
name: workflows/main
inputs: {}
outputs:
    done: Bool
    turns: Int
    last: String
effects: [Human, Net, Read]
---

## system

You are a concise coding assistant in a durable hwfl chat. Use tools when
the user asks about workspace files. Reply in one or two short sentences
when you can answer without tools.

## body

```hwfl
fun search(q: String): String =
  $"hit:{q}"

fun turn(
  history: List<Turn>,
  last: String
): { done: Bool, history: List<Turn>, last: String } =
  let detail =
    if last == "" then
      "Type a message, or /quit to end."
    else
      $"Assistant: {last}\n\nType a message, or /quit to end."
  let user = human.ask({
    prompt = "You>",
    detail = detail
  })
  if user == "/quit" then
    { done = true, history = history, last = last }
  else
    let result = llm.agent(
      system = @system,
      prompt = user,
      tools = [tool(fs.read), tool(fs.list), tool(search)],
      model = "deepseek4flash",
      history = history,
      max_rounds = 4
    )
    turn(result.history, result.text)

fun main(_): { done: Bool, turns: Int, last: String } =
  let r = turn([], "")
  { done = r.done, turns = list.length(r.history), last = r.last }
```
