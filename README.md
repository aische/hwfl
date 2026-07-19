# hwfl

Durable workflow **runtime** (Haskell library + CLI). Programs are typed
markdown modules: prose and an ML-ish kernel share one file. LLM calls,
filesystem, `exec`, parallelism, and human confirm are host effects with
checkpointed resume.

## Why

Agentic systems usually bury prompts in host-language glue, or use a thin
step DSL that falls over when real computation shows up. hwfl keeps
document-shaped authoring and a small general-purpose language in one
module, then runs it durably and observably.

## Example

`examples/coding-agent` is a universal coding agent. The project entrypoint
(`workflows/main.md`) is a single markdown module — frontmatter, prose
prompts, and a `hwfl` fence:

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

The **agent project** is `examples/coding-agent`; the **target tree** is
whatever you pass as `--workspace`.

## Quick start

Needs GHC + Cabal, a configured `model-catalog.json`, and provider credentials
(see `.env` for the usual key names).

```bash
cabal build hwfl
cabal run hwfl -- check examples/coding-agent

mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/coding-agent \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a pytest that checks add(2,3)==5' \
  --input model=deepseek4flash \
  --llm-provider simple
```

Run state lands under `/tmp/hwfl-build/.hwfl/runs/<run-id>/`. Use
`hwfl show`, `approve`, `choose`, `reply`, and `resume` for paused or
stepped runs — see [docs/tutorial.md](docs/tutorial.md). Chat-style
workflows: [examples/chat.md](examples/chat.md).

More stacks and options: [examples/coding-agent/README.md](examples/coding-agent/README.md).

## Layout

| Path | Role |
| ---- | ---- |
| `src/Hwfl/` | Library: parse, check, eval, durable runtime, LLM, observability |
| `app/` | CLI wrapping the driver façade |
| `examples/` | Example modules and projects |
| `docs/` | Spec, architecture, language reference |

## Docs

- [docs/tutorial.md](docs/tutorial.md) — check → run → approve → resume → show
- [docs/language-reference.md](docs/language-reference.md) — surface language
- [docs/architecture.md](docs/architecture.md) — layers and boundaries
- [examples/chat.md](examples/chat.md) — workflow chat (`human.ask` + `/quit`)
