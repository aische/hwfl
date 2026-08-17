# Tutorial: run lifecycle

Walk through the durable CLI loop: **init → check → run (mock) →
approve → show**. Language surface:
[language-reference.md](language-reference.md). More programs live under
`examples/`.

## Prerequisites

From the repo root:

```bash
cabal build hwfl
```

Commands below use `cabal run hwfl -- …`. After install, `hwfl` alone is
equivalent. No API keys are required for this tutorial (`--llm-provider
mock`). Real LLM calls need a configured `model-catalog.json` and provider
credentials (see `.env`).

## 1. Mental model

| Piece | Role |
| ----- | ---- |
| **Module** | One markdown file: YAML frontmatter + one `hwfl` code fence with `main` |
| **Project** | Directory with `project.json` + modules (multi-file graph) |
| **Workspace** | Sandbox for file / exec effects (`--workspace`; project runs default to the project root) |
| **Run** | One execution; id printed as `hwfl run: run_id=…`; state under `.hwfl/runs/<id>/` |

**Project vs workspace:** the project (or module path) is *code*; the
workspace is *data*. Agents and `fs.*` / `exec.*` see the workspace, not
the module tree (unless you point `--workspace` at the project itself).

Runs persist snapshots and spans so you can pause for human confirm,
step one transition, crash, and continue without redoing finished host
ops.

## 2. Init

Scaffold a tiny project (LLM call + confirm gate):

```bash
mkdir -p /tmp/hwfl-hello
cabal run hwfl -- init /tmp/hwfl-hello
```

That writes `project.json` and `workflows/main.md`. The entrypoint calls
`llm.chat`, then `confirm`, and returns `{ greeting, ok }`.

## 3. Check

Static load: parse, types, effects. No host side effects.

```bash
cabal run hwfl -- check /tmp/hwfl-hello
```

Exit `0` on success; diagnostics on stderr and exit `1` on failure.

## 4. Run (mock)

Use the project directory as the workspace so run state lands next to the
code (project ≠ workspace in general; here they coincide on purpose).
When the run target is a project directory, `run` derives the workspace from
that project automatically. An explicit `--workspace` still overrides it.

```bash
cabal run hwfl -- run /tmp/hwfl-hello \
  --llm-provider mock
```

Stderr includes `hwfl run: run_id=<id>` and a pause line such as
`awaiting confirm: Accept this greeting?`. Exit code is `3` (paused).
Continue commands can omit the run id (or pass `latest`) to pick the
newest run in the workspace.

The mock provider needs no network or catalog. Persistence lands in:

```text
/tmp/hwfl-hello/.hwfl/runs/<run-id>/
  meta.json
  snapshot.json
  spans.jsonl
  …
```

`run` checks first unless you pass `--no-check`.

## 5. Approve and show

Approve the confirm gate (injects `true` and resumes). Approve / show /
resume take the **workspace** (here the same directory). Omit the run id
(or pass `latest`) to continue the newest run:

```bash
cabal run hwfl -- approve /tmp/hwfl-hello --yes
# stdout: {greeting:"SUMMARY: Say hello…",ok:true}
```

Use `--no` to inject `false`. Inspect status and the span tree:

```bash
cabal run hwfl -- show /tmp/hwfl-hello
```

You should see a module span, an `llm.chat` span, and the confirm pause
resolved. Useful flags:

| Flag | Meaning |
| ---- | ------- |
| (default) / `--tree` | Summary + nested spans |
| `--spans` | Flat span lines |
| `--spans --filter PREFIX` | Filter by name prefix (e.g. `llm`, `fs`) |
| `--snapshot` | Redacted machine snapshot (debug) |

Live tracing while running:

```bash
cabal run hwfl -- run /tmp/hwfl-hello \
  --workspace /tmp/hwfl-hello \
  --llm-provider mock \
  --debug
```

`--debug` streams span open/close on stderr and prints the tree at the
end (`-v` / `--verbose` only prints the end tree).

## 6. Resume without approve

If a run is paused and you only want to continue after an external fix
(or after resolving a gate another way):

```bash
cabal run hwfl -- resume /tmp/hwfl-hello
```

`show` while paused reports `status: awaiting_confirm` (or `paused`) and
a cursor hint.

Related gates (same exit-`3` pause model):

| Gate | Resolve |
| ---- | ------- |
| `confirm` / `human.confirm` | `hwfl approve <ws> [run-id] --yes\|--no` |
| `choice` / `human.choice` | `hwfl choose <ws> [run-id] --select <option>` |
| `human.ask` | `hwfl reply <ws> [run-id] --text "…"` |

With `--interactive` on a TTY, `run` prompts on stdin and resolves gates
in-process (no exit-`3` between turns):

```bash
cabal run hwfl -- run /tmp/hwfl-hello \
  --workspace /tmp/hwfl-hello \
  --llm-provider mock \
  --interactive
```

### One transition at a time

```bash
cabal run hwfl -- run /tmp/hwfl-hello \
  --workspace /tmp/hwfl-hello \
  --llm-provider mock \
  --step
cabal run hwfl -- step /tmp/hwfl-hello
cabal run hwfl -- resume /tmp/hwfl-hello
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

## 8. Optional next steps

**File + real LLM** — `examples/summarise.md` reads a workspace file and
calls `llm.chat` with the default (`simple`) provider:

```bash
mkdir -p /tmp/hwfl-tut
echo 'hwfl is a typed markdown workflow language.' > /tmp/hwfl-tut/note.md
cabal run hwfl -- run examples/summarise.md \
  --workspace /tmp/hwfl-tut \
  --input path=note.md \
  --example note
```

**Pure spans** — `examples/obs-span.md` is a no-LLM module that only uses
`obs.span`.

**Workflow chat** — [examples/chat](../examples/chat) (`human.ask` +
`/quit`).

| Doc / example | When |
| ------------- | ---- |
| [language-reference.md](language-reference.md) | Keywords, types, prelude, host ops |
| [stdlib.md](stdlib.md) | `hwfl/*` stdlib + `HWFL_STDLIB` vs host |
| `examples/coding-agent` | Chat → coding session → serial task/verify |
| `examples/simple-coding-agent` | Flat `llm.agent_object` + stack skills |
| `examples/skills` | Minimal `skill.discover` / `skill.load` |
| `examples/compare` | Nested runs: compare → mutate → next generation |
| `examples/evolve-agent` | Nested runs: evolve agent variants on a fixture |
| `examples/semantic-check` | Multi-layer review workflow |
| `examples/story-writer` | MCP fixture: continuity clash / snapshot |
| `examples/real-story-writer` | Multi-chapter story pipeline + KB repair |

The coding session (`workflows/coding`) lists `skill.discover` /
`skill.load` and loads stack instruction skills (python / react /
haskell / rust) mid-loop; chat only exposes `coding_session`.
