---
name: workflows/coding
inputs:
  prompt: String
  model: String
outputs:
  summary: String
  ok: Bool
  stack: String
  files_written: List<String>
  verify_exit: Int
  tasks_done: Int
  tasks_total: Int
effects: [Read, Write, Net, Exec, Meta]
imports:
  - workflows/gather_context
  - workflows/verify
---

## plan-system

You are the planner for a coding session. Produce a short ordered task list.
Use skill_discover / skill_load when stack conventions affect the plan or
verify commands (pytest layout, cabal test, npm build, …).

Each task must be small enough for one implement→verify cycle. Set
verify_program to an allowlisted basename (python3, npm, cabal, cargo, …)
and verify_args to a concrete argv. Prefer non-interactive checks.

Call submit alone with the Plan. Never mix submit with other tools.

## do-system

You implement exactly one coding task in the workspace. Discover/load stack
skills when useful, then create or edit files with fs_write / fs_patch /
fs_edit. Prefer fs_patch for multi-site edits (each hunk.old must match
exactly once).

Do not call submit until the task’s files are in place. Verification runs
outside this agent — focus on implementation. Stay workspace-relative.

## schema Plan

- stack: Short toolchain label (python, typescript-react, haskell, rust, …).
- summary: One-sentence plan overview.
- tasks: Ordered implementable tasks with verify commands.

## schema TaskDone

- summary: What this task changed.
- files_written: Paths created or materially edited in this task.

## body

```hwfl
type Task = {
  id: String,
  title: String,
  detail: String,
  verify_program: String,
  verify_args: List<String>
}

type Plan = {
  stack: String,
  summary: String,
  tasks: List<Task>
}

type TaskDone = {
  summary: String,
  files_written: List<String>
}

fun merge_files(
  acc: List<String>,
  xs: List<String>,
  i: Int,
  n: Int
): List<String> =
  if i >= n then acc
  else if has_string(acc, xs[i], 0, list.length(acc)) then
    merge_files(acc, xs, i + 1, n)
  else
    merge_files(list.concat(acc, [xs[i]]), xs, i + 1, n)

fun has_string(xs: List<String>, s: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == s then true
  else has_string(xs, s, i + 1, n)

fun join_summaries(xs: List<String>, i: Int, n: Int): String =
  if i >= n then ""
  else if i == n - 1 then xs[i]
  else $"{xs[i]} | {join_summaries(xs, i + 1, n)}"

fun do_task(
  item: Task,
  prompt: String,
  context: String,
  model: String,
  feedback: String
): TaskDone =
  let extra =
    if feedback == "" then ""
    else $"\n\nPrevious verify failed:\n{feedback}\nFix the failure."
  let result = llm.agent_object(
    system = @do-system,
    prompt = $"User request:\n{prompt}\n\nWorkspace context:\n{context}\n\nTask {item.id}: {item.title}\n{item.detail}{extra}",
    tools = [
      tool(skill.discover),
      tool(skill.load),
      tool(fs.list),
      tool(fs.find),
      tool(fs.read),
      tool(fs.write),
      tool(fs.edit),
      tool(fs.patch),
      tool(fs.grep)
    ],
    schema = schema(TaskDone),
    model = model,
    max_rounds = 24
  )
  result.value

fun verify_task(item: Task): {
  exit: Int,
  stdout: String,
  stderr: String,
  ok: Bool
} =
  if item.verify_program == "" then
    { exit = 0, stdout = "", stderr = "", ok = true }
  else
    workflows/verify({
      program = item.verify_program,
      args = item.verify_args
    })

fun run_tasks(
  tasks: List<Task>,
  i: Int,
  n: Int,
  prompt: String,
  context: String,
  model: String,
  stack: String,
  summaries: List<String>,
  files: List<String>,
  last_exit: Int
): {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int,
  tasks_done: Int,
  tasks_total: Int
} =
  if i >= n then
    {
      summary = join_summaries(summaries, 0, list.length(summaries)),
      ok = true,
      stack = stack,
      files_written = files,
      verify_exit = last_exit,
      tasks_done = n,
      tasks_total = n
    }
  else
    let item = tasks[i]
    let done0 = do_task(item, prompt, context, model, "")
    let v0 = verify_task(item)
    if v0.ok then
      run_tasks(
        tasks,
        i + 1,
        n,
        prompt,
        context,
        model,
        stack,
        list.concat(summaries, [done0.summary]),
        merge_files(files, done0.files_written, 0, list.length(done0.files_written)),
        v0.exit
      )
    else
      let fb = $"exit={v0.exit}\nstdout:\n{v0.stdout}\nstderr:\n{v0.stderr}"
      let done1 = do_task(item, prompt, context, model, fb)
      let v1 = verify_task(item)
      if v1.ok then
        run_tasks(
          tasks,
          i + 1,
          n,
          prompt,
          context,
          model,
          stack,
          list.concat(summaries, [done1.summary]),
          merge_files(
            merge_files(files, done0.files_written, 0, list.length(done0.files_written)),
            done1.files_written,
            0,
            list.length(done1.files_written)
          ),
          v1.exit
        )
      else
        {
          summary = $"Stopped on item {item.id} ({item.title}) after retry. last verify exit={v1.exit}. stderr:\n{v1.stderr}",
          ok = false,
          stack = stack,
          files_written = merge_files(
            merge_files(files, done0.files_written, 0, list.length(done0.files_written)),
            done1.files_written,
            0,
            list.length(done1.files_written)
          ),
          verify_exit = v1.exit,
          tasks_done = i,
          tasks_total = n
        }

fun empty_strings(): List<String> = []

fun main(inputs: { prompt: String, model: String }): {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int,
  tasks_done: Int,
  tasks_total: Int
} =
  let ctx = workflows/gather_context({
    query = inputs.prompt,
    budget_tokens = 6000
  })
  let planned = llm.agent_object(
    system = @plan-system,
    prompt = $"User request:\n{inputs.prompt}\n\nWorkspace context ({ctx.tokens} tokens, files={list.length(ctx.files)}):\n{ctx.context}",
    tools = [
      tool(skill.discover),
      tool(skill.load)
    ],
    schema = schema(Plan),
    model = inputs.model,
    max_rounds = 8
  )
  let plan = planned.value
  let n = list.length(plan.tasks)
  if n == 0 then
    {
      summary = plan.summary,
      ok = true,
      stack = plan.stack,
      files_written = empty_strings(),
      verify_exit = 0,
      tasks_done = 0,
      tasks_total = 0
    }
  else
    run_tasks(
      plan.tasks,
      0,
      n,
      inputs.prompt,
      ctx.context,
      inputs.model,
      plan.stack,
      empty_strings(),
      empty_strings(),
      0
    )
```
