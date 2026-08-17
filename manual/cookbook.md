# Cookbook

Complete, legal patterns. Copy the envelope, then swap names. Signatures:
[cheatsheet](cheatsheet.md).

## Hello (LLM + confirm)

What `hwfl init` writes. Needs `Human` and `Net`. Mock provider is enough
to learn the pause loop.

````markdown
---
name: workflows/main
inputs: {}
outputs:
  greeting: String
  ok: Bool
effects: [Human, Net]
---

## system

You are brief. Reply in one short sentence.

## body

```hwfl
fun main(_): { greeting: String, ok: Bool } =
  let greeting = llm.chat(
    system = @system,
    prompt = "Say hello to a new hwfl author.",
    model = "deepseek4flash"
  )
  let ok = confirm {
    title = "Accept this greeting?",
    detail = greeting
  }
  { greeting, ok }
```
````

```bash
hwfl run . --llm-provider mock
hwfl approve . <run-id> --yes
```

## Summarise a file

Project vs workspace: the module is code; `--workspace` is where
`note.md` lives.

````markdown
---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
effects: [Read, Net]
examples:
  - name: note
    inputs:
      path: note.md
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## body

```hwfl
fun main(inputs): { summary: String } =
  let contents = fs.read(inputs.path)
  let summary = llm.chat(
    system = @system,
    prompt = $"Summarise the following:\n\n{contents.text}",
    model = "deepseek4flash"
  )
  { summary }
```
````

```bash
echo 'hwfl is a typed markdown workflow language.' > /tmp/ws/note.md
hwfl run . --workspace /tmp/ws --example note
```

## Structured object

````markdown
---
name: workflows/main
inputs: {}
outputs:
  summary: String
  score: Int
effects: [Net]
---

## schema Out

- summary: One sentence.
- score: Integer from 1 to 10.

## body

```hwfl
type Out = { summary: String, score: Int }

fun main(_): { summary: String, score: Int } =
  let out = llm.object(
    prompt = "Score the word 'hwfl' for pronounceability",
    schema = schema(Out),
    model = "deepseek4flash"
  )
  { summary = out.summary, score = out.score }
```
````

## Agent with tools

`tool(fs.read)` is `fs_read` in the model prompt. User `fun`s work too.

````markdown
---
name: workflows/main
inputs: {}
outputs:
  text: String
  rounds: Int
effects: [Read, Net]
---

## system

Use tools when needed. Prefer fs_read for file contents.

## body

```hwfl
fun search(q: String): String =
  $"hit:{q}"

fun main(_): { text: String, rounds: Int } =
  let result = llm.agent(
    system = @system,
    prompt = "find note",
    tools = [tool(fs.read), tool(search)],
    model = "deepseek4flash",
    max_rounds = 4
  )
  { text = result.text, rounds = result.rounds }
```
````

## Agent object (typed submit)

The model must call `submit` alone with the schema payload.

````markdown
---
name: workflows/main
inputs:
  prompt: String
  model: String
outputs:
  summary: String
  ok: Bool
  rounds: Int
effects: [Read, Write, Net, Exec]
---

## system

Implement the request. Verify with exec_run. Call submit alone when done.

## body

```hwfl
type Result = { summary: String, ok: Bool }

fun main(inputs: { prompt: String, model: String }): {
  summary: String,
  ok: Bool,
  rounds: Int
} =
  let result = llm.agent_object(
    system = @system,
    prompt = inputs.prompt,
    tools = [
      tool(fs.list),
      tool(fs.read),
      tool(fs.write),
      tool(fs.edit),
      tool(fs.patch),
      tool(exec.run)
    ],
    schema = schema(Result),
    model = inputs.model,
    max_rounds = 32
  )
  {
    summary = result.value.summary,
    ok = result.value.ok,
    rounds = result.rounds
  }
```
````

`exec.run` also needs `project.json` `exec.allow`.

## Chat loop (`human.ask`)

Top-level recursion. `--interactive` keeps the conversation on one TTY.

````markdown
---
name: workflows/main
inputs: {}
outputs:
  done: Bool
  last: String
effects: [Human, Net]
---

## system

You are a concise assistant. Reply in one or two short sentences.

## body

```hwfl
fun turn(last: String): { done: Bool, last: String } =
  let user = human.ask({
    prompt = "You>",
    detail = if last == "" then
      "Type a message, or /quit to end."
    else
      $"Assistant: {last}\n\nType a message, or /quit to end."
  })
  if user == "/quit" then
    { done = true, last = last }
  else
    let reply = llm.chat(
      system = @system,
      prompt = user,
      model = "deepseek4flash"
    )
    turn(reply)

fun main(_): { done: Bool, last: String } =
  turn("")
```
````

## Durable agent chat (history + window)

Keep `List<Turn>` across `human.ask` turns. Windowing is per
`llm.agent` call; pins do not survive the outer loop.

```hwfl
fun turn(history: List<Turn>, last: String): {
  done: Bool,
  history: List<Turn>,
  last: String
} =
  let user = human.ask({ prompt = "You>", detail = last })
  if user == "/quit" then
    { done = true, history = history, last = last }
  else
    let result = llm.agent(
      system = @system,
      prompt = user,
      tools = [tool(fs.read), tool(fs.write)],
      model = "deepseek4flash",
      history = history,
      max_rounds = 6,
      context_window = 4,
      consolidate = "heuristic"
    )
    turn(result.history, result.text)
```

## Lists via stdlib

```yaml
imports:
  - hwfl/list
  - hwfl/option
```

```hwfl
fun main(_): { mapped: List<Int>, head: Int } =
  let xs = [1, 2, 3, 4]
  let mapped = hwfl/list.map(xs, fun (n: Int): Int => n * 10)
  let head = hwfl/option.unwrap_or(hwfl/list.head(mapped), 0)
  { mapped = mapped, head = head }
```

## Same-project inner workflow

Callee is an entry module. Caller imports it and calls the qname. Same
run, no `Meta`.

Caller:

```yaml
imports:
  - workflows/inner
```

```hwfl
fun main(inputs): { summary: String } =
  let r = workflows/inner({ x = inputs.value, label = "first" })
  { summary = r.result }
```

Callee `workflows/inner.md` has its own `inputs` / `outputs` / `fun main`.

## Nested project (`meta.invoke`)

Use when the child has its own `project.json` / workspace (evolve,
compare). Caller needs `Meta` + `Read`.

```hwfl
meta.invoke(
  project = "genomes/lean",
  workspace = "genomes/lean",
  inputs = { n = 1 }
)
```

## Parallel confirm

Needs `Parallel` and `Human`. A confirm inside `par` freezes the pool.

```hwfl
fun main(inputs): { results: List<{ name: String, ok: Bool }> } =
  let results =
    par(max = 2) for name in inputs.packages {
      let ok = confirm {
        title = $"Install {name}?",
        detail = name
      }
      { name, ok }
    }
  { results }
```

## Choice gate

```hwfl
fun main(_): { env: String } =
  let env = choice {
    title = "Deploy target?",
    options = ["staging", "prod", "abort"]
  }
  { env }
```

```bash
hwfl choose . <run-id> --select staging
```

## Patch a file

Each `old` must match exactly once after prior hunks; failure is atomic.

```hwfl
fs.patch(
  path = "src/main.py",
  hunks = [
    { old = "def add(a, b):\n    return a - b\n", new = "def add(a, b):\n    return a + b\n" }
  ]
)
```

Use `fs.edit` only for intentional replace-all.

## Catch a missing file

```hwfl
try fs.read("maybe.md").text catch (err) => $"missing: {err}"
```

`err` is `String`. Traps and internal errors are not caught.
