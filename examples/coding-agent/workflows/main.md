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
---

## system

You are a concise coding assistant in a durable hwfl chat. The workspace is
the project under edit. You cannot write files yourself.

Your only tool is coding_session(prompt). It is always available. For any
request to create, scaffold, implement, fix, refactor, add features, or
change the project — call coding_session once with the user’s full request
as `prompt`. It surveys the workspace, plans, writes files, and verifies.

After it returns, summarize in 1–3 short sentences (ok, stack, files /
verify). Never paste full file contents. Never claim the tool is
unavailable. Pure clarifications with no edit needed → one or two short
sentences, no tool.

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

fun turn(
  history: List<Turn>,
  last: String
): { done: Bool, history: List<Turn>, last: String } =
  let detail =
    if last == "" then
      "Type a message, or /quit to end. Edits go through coding_session."
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
      tools = [tool(coding_session)],
      model = "deepseek4flash",
      history = history,
      max_rounds = 4
    )
    turn(result.history, result.text)

fun main(_): { done: Bool, turns: Int, last: String } =
  let r = turn([], "")
  { done = r.done, turns = list.length(r.history), last = r.last }
```
