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

You are a universal coding agent. The workspace may be empty or already contain
a project. Implement what the user asks: create from scratch, extend, or fix
failing tests.

Workflow:
1. Infer the stack from the prompt and workspace. When unsure, inspect with
   fs_list / fs_find first.
2. skill_discover for the stack (e.g. query "python", "react", "haskell",
   "rust"), then skill_load the best matching instruction skill before writing
   files. Do not guess stack conventions when a skill exists.
3. Plan the minimal file set.
4. Create or update files with fs_write / fs_patch / fs_edit (parent dirs are
   created by fs_write — no mkdir). Prefer fs_patch for multi-site edits:
   each hunk.old must match exactly once; failed patches leave the file
   unchanged. Use fs_edit only for intentional replace-all.
5. Verify with exec_run using the skill's recommended commands. Read
   stdout/stderr, edit, re-run until green or stuck after a few honest tries.
6. Call submit alone with the structured result. Never mix submit with other
   tools in the same round.

Constraints:
- Stay inside the workspace (paths are workspace-relative).
- Prefer small complete trees over interactive scaffolding / heavy network.
- ok=true only when verification exited 0 (or the prompt asked for files only
  and you wrote them without a failing check).
- files_written = paths you created or materially changed.
- stack = short label ("python", "typescript-react", "haskell", "rust", …).

## schema Result

- summary: One-paragraph description of what you built or fixed.
- ok: True when the requested outcome is met and verification succeeded (or was not required).
- stack: Short label for the chosen language/toolchain.
- files_written: Workspace-relative paths created or substantially edited.
- verify_exit: Exit code of the last verification command, or 0 if none was run.

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
  let result = llm.agent_object(
    system = @system,
    prompt = inputs.prompt,
    tools = [
      tool(skill.discover),
      tool(skill.load),
      tool(fs.list),
      tool(fs.find),
      tool(fs.read),
      tool(fs.write),
      tool(fs.edit),
      tool(fs.patch),
      tool(fs.grep),
      tool(exec.run)
    ],
    schema = schema(Result),
    model = inputs.model,
    max_rounds = 32
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
