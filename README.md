# hwfl

[![CI](https://github.com/aische/hwfl/actions/workflows/ci.yml/badge.svg)](https://github.com/aische/hwfl/actions/workflows/ci.yml)

**hwfl** is a small programming language for writing AI workflows as
**typed markdown modules** — prose and code in one file, the way PHP
once mixed HTML and logic for the web. The ML-ish kernel gives you real
expressions (`let`, functions, records, `match`, `par`) so you never
reach for a micro-tool to work around a missing form. LLM calls,
filesystem, `exec`, human confirm, and MCP clients are first-class host
effects with automatic checkpointing: pause, resume after crash, or
approve a confirm gate from the CLI.

The same interpreter is available as a **Haskell library** for frontends
that want programmatic check/run/step/resume without the CLI.

**Vision and goals:** [docs/idea.md](docs/idea.md)

## Why not just use Python?

Agentic systems written in general-purpose languages end up splitting
work awkwardly: orchestration logic in the host language, prompts as
string constants buried in that code, and a step DSL bolted on top that
collapses the moment you need a conditional. hwfl puts prompts and prose
**in the file as first-class sections** (bindable as `@slug`), type-checks
the whole project before the first billed token, and resumes from the
last checkpoint after any crash or human pause.

## Quick start

Run the test suite, build the CLI, and try the bundled hello-world project:

```bash
cabal test
cabal build exe:hwfl
cabal run exe:hwfl -- init /tmp/hwfl-hello
cabal run exe:hwfl -- check /tmp/hwfl-hello
cabal run exe:hwfl -- run /tmp/hwfl-hello \
  --workspace /tmp/hwfl-hello \
  --llm-provider mock
# exit 3 — omit the run id (or pass latest):
cabal run exe:hwfl -- approve /tmp/hwfl-hello --yes
cabal run exe:hwfl -- show /tmp/hwfl-hello
```

Full walkthrough: [manual/tutorial.md](manual/tutorial.md).

## Examples

### One-shot coding agent

`examples/simple-coding-agent` is a flat `llm.agent_object` loop — skills,
filesystem, `exec.run`, then a typed `submit`. The full main module fits in one
markdown file; here it is unabridged so you can see what a real hwfl program
looks like:

````markdown
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
examples:
  - name: todo-vite
    inputs:
      model: deepseek4flash
      prompt: write a typescript/vite/react project with a todo app
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
````

```bash
cabal build hwfl
cabal run hwfl -- check examples/simple-coding-agent

mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/simple-coding-agent \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a pytest that checks add(2,3)==5' \
  --input model=deepseek4flash \
  --llm-provider simple
```

### Skill-driven coding agent

`examples/coding-agent` is the fuller shape: a chat loop (`human.ask`)
delegates implementation to a `coding_session` tool (typed plan → serial
implement/verify). Skills are discovered and loaded mid-loop so the agent
context stays small until a specific stack is identified.

```bash
cabal run hwfl -- check examples/coding-agent

# Interactive chat (type at You>; /quit to end)
cabal run hwfl -- run examples/coding-agent \
  --workspace /tmp/hwfl-build \
  --interactive \
  --input model=deepseek4flash \
  --llm-provider simple

# Non-interactive coding session (bypass chat)
mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/coding-agent/workflows/coding.md \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a check' \
  --input model=deepseek4flash \
  --llm-provider simple
```

Needs a configured `model-catalog.json` and provider credentials (see `.env`).
Run state lands under the workspace at `.hwfl/runs/<run-id>/` — inspect it with
`hwfl show` or read the `spans.jsonl` / `events.jsonl` directly.

More:
[examples/simple-coding-agent/README.md](examples/simple-coding-agent/README.md),
[examples/coding-agent/README.md](examples/coding-agent/README.md),
[manual/tutorial.md](manual/tutorial.md).

## Layout

| Path | Role |
| ---- | ---- |
| `src/Hwfl/` | Library: parse, check, eval, durable runtime, LLM, observability |
| `app/` | CLI wrapping the driver façade |
| `examples/` | Example programs (agents, story pipelines, compare/evolve, …) |
| `manual/` | Author manual: tutorial, cheatsheet, library reference |
| `docs/` | Spec, architecture, maintainer internals |

## Further reading

| | |
|---|---|
| [manual/tutorial.md](manual/tutorial.md) | Step-by-step: write, check, run, resume, show |
| [manual/](manual/README.md) | Full author book (cheatsheet, library reference) |
| [docs/idea.md](docs/idea.md) | Vision, goals, non-goals, constraints |
| [docs/architecture.md](docs/architecture.md) | Layers, stdlib policy, package layout |
| [examples/](examples/) | Runnable example projects |
