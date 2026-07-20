# Tutorial: run lifecycle

Walk through the durable CLI loop: **module → check → run → (approve) →
resume → show**. Language surface is in
[language-reference.md](language-reference.md); agent dogfood is in
`examples/coding-agent`.

## Prerequisites

From the repo root:

```bash
cabal build hwfl
```

Commands below use `cabal run hwfl -- …`. After install, `hwfl` alone is
equivalent.

You need no API keys for the first sections (`obs-span`, confirm, and
`--llm-provider mock`). Real LLM calls need a configured
`model-catalog.json` and provider credentials (see `.env`).

## 1. Mental model

| Piece | Role |
| ----- | ---- |
| **Module** | One markdown file: YAML frontmatter + one `hwfl` code fence with `main` |
| **Project** | Directory with `project.json` + modules (multi-file graph) |
| **Workspace** | Sandbox for file / exec effects (`--workspace`; defaults to cwd) |
| **Run** | One execution; id printed as `hwfl run: run_id=…`; state under `.hwfl/runs/<id>/` |

**Project vs workspace:** the project (or module path) is *code*; the
workspace is *data*. Agents and `fs.*` / `exec.*` see the workspace, not
the module tree (unless you point `--workspace` at the project itself).

Runs persist snapshots and spans so you can pause for human confirm,
step one transition, crash, and continue without redoing finished host
ops.

## 2. A tiny module

`examples/obs-span.md` is pure (no LLM, no filesystem):

```yaml
---
name: workflows/obs-span
inputs: {}
outputs:
    n: Int
    label: String
effects: []
---
```

```hwfl
fun main(_): { n: Int, label: String } =
  let clustered = obs.span("cluster")(fun () =>
    { n = 3, label = "ok" }
  )
  clustered
```

Frontmatter declares the qname (`name` must match the path without
`.md`), typed `inputs` / `outputs`, and an **effects** ceiling. The kernel
block defines `main`.

## 3. Check

Static load: parse, types, effects. No host side effects.

```bash
cabal run hwfl -- check examples/obs-span.md
```

Exit `0` on success; diagnostics on stderr and exit `1` on failure.

For a project directory (`project.json` present):

```bash
cabal run hwfl -- check examples/coding-agent
```

That checks the whole import graph, not only the entrypoint file.

## 4. Run

```bash
mkdir -p /tmp/hwfl-tut
cabal run hwfl -- run examples/obs-span.md --workspace /tmp/hwfl-tut
```

Stderr includes `hwfl run: run_id=<id>`. Stdout is the result value, e.g.
`{label:"ok",n:3}`.

`run` checks first unless you pass `--no-check`. Persistence lands in:

```text
/tmp/hwfl-tut/.hwfl/runs/<run-id>/
  meta.json
  snapshot.json
  spans.jsonl
  …
```

### Inputs and LLM (optional)

`examples/summarise.md` reads a workspace file and calls `llm.chat`. Put a
file in the workspace and pass inputs as `k=v`:

```bash
echo 'hwfl is a typed markdown workflow language.' > /tmp/hwfl-tut/note.md
cabal run hwfl -- run examples/summarise.md \
  --workspace /tmp/hwfl-tut \
  --input path=note.md \
  --llm-provider mock
```

Use `--llm-provider simple` (default) for a real catalog-backed call.
`--input` values are coerced from strings to the declared input types
(`FileRef`, `String`, `Int`, `Bool`, …).

## 5. Show

Inspect status and the span tree for any run id:

```bash
cabal run hwfl -- show /tmp/hwfl-tut <run-id>
```

Useful flags:

| Flag | Meaning |
| ---- | ------- |
| (default) / `--tree` | Summary + nested spans |
| `--spans` | Flat span lines |
| `--spans --filter PREFIX` | Filter by name prefix (e.g. `llm`, `fs`) |
| `--snapshot` | Redacted machine snapshot (debug) |

After a successful `obs-span` run you should see a module span and a
`cluster` region. Host ops (`fs.read`, `llm.chat`, …) each get their own
span; agent tool calls appear as `tool:<name>` under agent rounds.

Live tracing while running:

```bash
cabal run hwfl -- run examples/obs-span.md \
  --workspace /tmp/hwfl-tut \
  --debug
```

`--debug` streams span open/close on stderr and prints the tree at the
end (`-v` / `--verbose` only prints the end tree).

`--cost` prefixes the usual host progress lines with running LLM spend
(`$0.12 │ fs.read …`) without enabling the debug span stream.

## 6. Pause, approve, resume

Host ops that need a human gate leave the machine **paused** (CLI exit
code `3`). The usual gate is `confirm` / `human.confirm` (and
`exec.run` when `project.json` has `"exec": { "confirm": true }`).

Save this as `/tmp/hwfl-tut/confirm.md`:

````markdown
---
name: workflows/confirm
inputs: {}
outputs:
  ok: Bool
effects: [Human]
---

## body

```hwfl
fun main(_): { ok: Bool } =
  let ok = confirm { title = "Proceed?", detail = "tutorial gate" }
  { ok }
```
````

Run it:

```bash
cabal run hwfl -- run /tmp/hwfl-tut/confirm.md --workspace /tmp/hwfl-tut
# stderr: awaiting confirm: Proceed?
# exit 3 — note the run_id
```

Approve and continue (approve injects the boolean and resumes):

```bash
cabal run hwfl -- approve /tmp/hwfl-tut <run-id> --yes
# stdout: {ok:true}
```

Use `--no` to inject `false`. If a run is paused for other reasons (or
you only want to continue after an external fix):

```bash
cabal run hwfl -- resume /tmp/hwfl-tut <run-id>
```

`show` while paused reports `status: awaiting_confirm` (or `paused`) and
a cursor hint so you can see where the machine stopped.

Related gates (same exit-`3` pause model):

| Gate | Resolve |
| ---- | ------- |
| `choice` / `human.choice` | `hwfl choose <ws> <run-id> --select <option>` |
| `human.ask` | `hwfl reply <ws> <run-id> --text "…"` |

Workflow-owned chat (history + `/quit`): [examples/chat](../examples/chat).
The previous assistant reply is placed in the next `human.ask` `detail`,
so any client (CLI or control plane) can show it from the pause payload
without a library print path. With `--interactive` on a TTY, `run`
prompts on stdin and resolves gates in-process (no exit-`3` between turns):

```bash
cabal run hwfl -- run examples/chat --workspace /tmp/hwfl-tut --interactive
```

### One transition at a time

```bash
cabal run hwfl -- run examples/obs-span.md --workspace /tmp/hwfl-tut --step
cabal run hwfl -- step /tmp/hwfl-tut <run-id>
cabal run hwfl -- resume /tmp/hwfl-tut <run-id>
```

`--step` / `step` advance one durable transition, then pause (exit `3`).

## 7. Exit codes

| Code | Meaning |
| ---- | ------- |
| 0 | Completed successfully |
| 1 | Check or runtime failure |
| 2 | Usage / bad flags |
| 3 | Paused (confirm, `--step`, …) |
| 4 | Stale project hash — resume refused after code change |

## 8. Where to go next

| Doc / example | When |
| ------------- | ---- |
| [language-reference.md](language-reference.md) | Keywords, types, prelude, host ops |
| `examples/coding-agent` | Full agent loop + stack skills over a workspace |
| `examples/skills` | Minimal `skill.discover` / `skill.load` demo |
| `examples/compare` | Lab: compare → mutate genomes → next generation |
| `examples/semantic-check` | Multi-layer review workflow |

The coding-agent lists `skill.discover` / `skill.load` explicitly and loads
stack instruction skills (python / react / haskell / rust) mid-loop.
