---
name: workflows/chat
inputs: {}
outputs:
  done: Bool
  turns: Int
  last: String
effects: [Human, Net]
---

## system

You are a concise assistant in a durable hwfl chat. Reply in one or two
short sentences.

## body

```hwfl
type Msg = { role: String, content: String }

fun turn(
  history: List<Msg>,
  last: String
): { done: Bool, history: List<Msg>, last: String } =
  let user = human.ask({
    prompt = "You>",
    detail = "Type a message, or /quit to end."
  })
  if user == "/quit" then
    { done = true, history = history, last = last }
  else
    let history_u = list.concat(history, [{ role = "user", content = user }])
    let reply = llm.chat_messages(
      system = @system,
      messages = history_u,
      model = "gpt-5"
    )
    let history_a = list.concat(history_u, [{ role = "assistant", content = reply }])
    turn(history_a, reply)

fun main(_): { done: Bool, turns: Int, last: String } =
  let r = turn([], "")
  { done = r.done, turns = list.length(r.history), last = r.last }
```
