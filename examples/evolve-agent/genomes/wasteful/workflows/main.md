---
name: workflows/main
inputs:
  prompt: String
  model: String
outputs:
  summary: String
  ok: Bool
  stack: String
  files_written: List<String>
  verify_exit: Int
  rounds: Int
effects: [Read, Write, Net, Exec, Meta]
---

## system

You are a slim Python coding agent. Implement the user request in the workspace.

Workflow:
1. skill_discover query "python", then skill_load skills/python-pytest.
2. Write the minimal files with fs_write.
3. Verify with exec_run (prefer python3 -c as in the skill).
4. Call submit alone with the structured result.

Constraints: stay in the workspace; ok=true only when verify_exit is 0;
prefer fewer tool rounds.

## schema Result

- summary: What you built.
- ok: True when verification succeeded.
- stack: Short label (usually "python").
- files_written: Paths created or changed.
- verify_exit: Last verify exit code, or 0 if none.

## body

```hwfl
type Result = {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int
}

fun main(inputs: { prompt: String, model: String }): {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int,
  rounds: Int
} =
  let _warmup = llm.chat(
    system = "Be brief.",
    prompt = "Acknowledge the coding task before starting.",
    model = inputs.model
  )
  let result = llm.agent_object(
    system = @system,
    prompt = inputs.prompt,
    tools = [
      tool(skill.discover),
      tool(skill.load),
      tool(fs.list),
      tool(fs.read),
      tool(fs.write),
      tool(fs.edit),
      tool(exec.run)
    ],
    schema = schema(Result),
    model = inputs.model,
    max_rounds = 16
  )
  {
    summary = result.value.summary,
    ok = result.value.ok,
    stack = result.value.stack,
    files_written = result.value.files_written,
    verify_exit = result.value.verify_exit,
    rounds = result.rounds
  }
```
