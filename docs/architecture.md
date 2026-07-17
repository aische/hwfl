# Architecture

## Three layers

````text
┌─────────────────────────────────────────────────────────────┐
│  L1 Surface — Markdown modules                              │
│  frontmatter (I/O, effects) · prose sections · ```hwfl blocks │
└────────────────────────────┬────────────────────────────────┘
                             │ load + elaborate
┌────────────────────────────▼────────────────────────────────┐
│  L2 Kernel — small typed ML                                 │
│  AST · type check · effect check · stdlib (in-language)     │
└────────────────────────────┬────────────────────────────────┘
                             │ evaluate
┌────────────────────────────▼────────────────────────────────┐
│  L3 Runtime — durable interpreter                           │
│  frames · host ops · LlmProvider · snapshots · spans        │
└─────────────────────────────────────────────────────────────┘
````

**L1** is how humans and agents author.  
**L2** is what is legal and ergonomic to compute.  
**L3** is how it runs durably and observably.

Do not merge L1 and L2 (markdown is packaging, not the AST).  
Do not put durability policy into L2 syntax (authors don’t write checkpoint pragmas).

## Haskell package shape (suggested)

```text
hwfl/
  app/Main.hs                 # CLI
  src/Hwfl/
    Ast/                      # Expr, Decl, Type, Pat, Module
    Parse/                    # Kernel + markdown loader
    Check/                    # Types + effects + project graph
    Eval/                     # pure big-step evaluator
    Runtime/
      Machine.hs              # frames, host/par/confirm transitions
      Snapshot.hs
      Host.hs                 # dispatch host ops
      Workspace.hs            # sandbox FS
      Exec.hs                 # opt-in process spawn
    Llm/
      Provider.hs             # typeclass / record of ops
      Simple.hs               # llm-simple adapter (default)
    Obs/
      Span.hs
      Trace.hs
    Project.hs                # load project tree
    Cli.hs
  test/
  examples/
```

Exact module names are not normative; boundaries are.

## Host boundary

All side effects go through **host ops** registered in the runtime:

| Category    | Examples                                              |
| ----------- | ----------------------------------------------------- |
| FS          | `fs.read`, `fs.write`, `fs.edit`, `fs.patch`, …       |
| LLM         | `llm.chat`, `llm.object`, `llm.agent`                 |
| Process     | `exec.run`                                            |
| Human       | `human.confirm`                                       |
| Meta        | `meta.eval_module`, `meta.list_runs`, `obs.log`       |
| Concurrency | `par` / `join` (runtime constructs, not user threads; M5 pool is cooperative — see [spec/06-runtime.md](spec/06-runtime.md) §10) |

Host ops:

1. Appear as ordinary function calls in surface syntax (or sugar).
2. Are typed and effect-annotated.
3. Are the **only** resume/snapshot boundaries (plus module entry/return / par join).
4. Emit a span with redacted args + timing (+ token usage for LLM).

## Provider boundary (LLM)

```text
Workflow ──► llm.* host ops ──► LlmProvider ──► llm-simple
                                   │
                                   └──► FutureProvider
```

Workflows never import `llm-simple`. Only `Hwfl.Llm.Simple` (or equivalent)
depends on it. See [spec/08-llm-provider.md](spec/08-llm-provider.md).

## Persistence layout (local v0)

Per workspace (names illustrative):

```text
.hwfl/
  runs/<run-id>/
    meta.json           # project hash, entry, started_at, status
    snapshot.json       # latest machine (or sequenced snapshots)
    spans.jsonl         # structured span open/close
    events.jsonl        # append-only audit (compat / debug)
```

Progress is defined by **snapshot**, not by replaying the event log.

## Project layout (author)

```text
project.json            # name, entrypoint, env allowlist, exec policy
model-catalog.json      # models ↔ providers (provider-agnostic config)
.env                    # API keys (host only; never in ctx)
workflows/*.md
tools/*.md              # optional libraries / callable modules
skills/*.md             # agent skills (callable / instruction; see skills-plan.md)
types/*.md              # shared type aliases (optional; or in-language types)
lib/*.md                # pure/effectful libraries
```

## Check vs run

```text
hwfl check <project>     # load, parse, type, effects, graph — no host side effects
hwfl run   <project> …   # check (or reuse) then evaluate
hwfl step / resume / show / approve
```

These commands are **one frontend** over a library driver. The same
operations (plus run-store queries and an observer hook for live spans /
pause) are what a future control-plane HTTP/WS app should call — without
Servant living in this repo. See [idea.md](idea.md) north star.

## Library vs control plane

```text
┌─────────────────────────────────────────────────────────────┐
│  Frontends (this repo: CLI; other repo: HTTP/WS/chat)       │
└────────────────────────────┬────────────────────────────────┘
                             │ driver façade
┌────────────────────────────▼────────────────────────────────┐
│  hwfl library — check / run / step / resume / approve / show │
│  run-store interface (FS today; optional DB backend later)   │
│  project root + workspace sandbox + LlmProvider              │
└─────────────────────────────────────────────────────────────┘
```

**Control plane (separate project):** auth, tenants, Postgres experiment /
run metadata, queue, materialize project + workspace temp dirs, map
pause/approve over WebSocket or SSE. It must not reimplement the machine;
it persists metadata and schedules sandboxed `hwfl` library runs.

**Genetic lab (example / later workflow):** treat project trees as
candidates (genome), workspaces as task fixtures + run sandboxes, invoke
nested runs (`meta.invoke` when shipped), score from spans / outcome /
cost. Prefer in-language evolution over a host “evolution engine.”

## Project vs workspace

| Root | Role |
| ---- | ---- |
| **Project** | Markdown modules, `project.json`, skills — the program (lab: genome) |
| **Workspace** | Sandboxed FS + `.hwfl/runs` — data and durable run state |

CLI already accepts `--workspace`. Lab and control plane should materialize
both as directories (often temp); do not collapse them into one tree unless
the task truly is “edit the project in place.”

## Stdlib policy

- Prefer **hwfl modules** under `lib/` for list/string/json helpers.
- Host ops only when the implementation _must_ be in Haskell (LLM, FS sandbox,
  process, snapshot, true parallelism).
- Never grow the host op set to paper over a missing kernel feature.

## Relationship of control flow constructs

| Construct                      | Layer                  | Notes                     |
| ------------------------------ | ---------------------- | ------------------------- |
| `let` / `fun` / `match` / `if` | L2 pure                | No snapshot mid-reduction |
| `par` / `join`                 | L3 sugar + frames      | Structured concurrency (cooperative today; concurrent host IO future) |
| `confirm`                      | L3 host / Human effect | Freezes `par` pool        |
| `try` / `catch` or `Result`    | L2 (+ catch frames)    | Catchable host errors     |
| Agent tool loop                | L3 state machine       | Like hwfi agent `Current` |
| Skills discover / load         | L3 host + agent state  | [skills-plan.md](skills-plan.md) |
