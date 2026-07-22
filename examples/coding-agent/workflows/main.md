---
name: workflows/main
inputs: {}
outputs:
  done: Bool
  turns: Int
  last: String
effects: [Human, Net, Read, Write, Exec, Meta]
imports:
  - workflows/coding
  - workflows/gather_context
---

## system

You are a concise coding assistant in a durable hwfl chat. The workspace is
the project under edit.

Tools:
- gather_context — read-only survey of the workspace under a token budget.
  Use for questions about existing files without changing anything.
- coding_session — implement or fix something. Pass the user’s request as
  prompt. Returns a typed { summary, ok, stack, files_written, verify_exit,
  tasks_done, tasks_total }. Summarize the result for the user.

Do not invent file contents when gather_context or coding_session can answer.
Reply in one or two short sentences when no tool is needed.
Type /quit ends the session (handled outside the model).

## body

```hwfl
fun coding_session(prompt: String): {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int,
  tasks_done: Int,
  tasks_total: Int
} =
  workflows/coding({
    prompt = prompt,
    model = "deepseek4flash"
  })

fun gather_context(query: String): {
  context: String,
  files: List<FileRef>,
  tokens: Int
} =
  workflows/gather_context({
    query = query,
    budget_tokens = 4000
  })

fun turn(
  history: List<Turn>,
  last: String
): { done: Bool, history: List<Turn>, last: String } =
  let detail =
    if last == "" then
      "Type a message, or /quit to end. Use coding_session for edits."
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
      tools = [
        tool(gather_context),
        tool(coding_session)
      ],
      model = "deepseek4flash",
      history = history,
      max_rounds = 6
    )
    turn(result.history, result.text)

fun main(_): { done: Bool, turns: Int, last: String } =
  let r = turn([], "")
  { done = r.done, turns = list.length(r.history), last = r.last }
```
