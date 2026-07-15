# Architecture

## Three layers

```text
┌─────────────────────────────────────────────────────────────┐
│  L1 Surface — Markdown modules                              │
│  frontmatter (I/O, effects) · prose sections · ```pml blocks │
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
```

**L1** is how humans and agents author.  
**L2** is what is legal and ergonomic to compute.  
**L3** is how it runs durably and observably.

Do not merge L1 and L2 (markdown is packaging, not the AST).  
Do not put durability policy into L2 syntax (authors don’t write checkpoint pragmas).

## Haskell package shape (suggested)

```text
pml/
  app/Main.hs                 # CLI
  src/Pml/
    Ast/                      # Expr, Decl, Type, Pat, Module
    Parse/                    # Kernel + markdown loader
    Check/                    # Types + effects + project graph
    Eval/                     # CEK / frame driver
    Runtime/
      Machine.hs              # status, frames, path, bindings
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

| Category | Examples |
|----------|----------|
| FS | `fs.read`, `fs.write`, `fs.list`, … |
| LLM | `llm.chat`, `llm.object`, `llm.agent` |
| Process | `exec.run` |
| Human | `human.confirm` |
| Meta | `meta.eval_module`, `meta.list_runs`, `obs.log` |
| Concurrency | `par` / `join` (runtime constructs, not user threads) |

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

Workflows never import `llm-simple`. Only `Pml.Llm.Simple` (or equivalent)
depends on it. See [spec/08-llm-provider.md](spec/08-llm-provider.md).

## Persistence layout (local v0)

Per workspace (names illustrative):

```text
.pml/
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
types/*.md              # shared type aliases (optional; or in-language types)
lib/*.md                # pure/effectful libraries
```

## Check vs run

```text
pml check <project>     # load, parse, type, effects, graph — no host side effects
pml run   <project> …   # check (or reuse) then evaluate
pml step / resume / show / approve
```

## Stdlib policy

- Prefer **pml modules** under `lib/` for list/string/json helpers.
- Host ops only when the implementation *must* be in Haskell (LLM, FS sandbox,
  process, snapshot, true parallelism).
- Never grow the host op set to paper over a missing kernel feature.

## Relationship of control flow constructs

| Construct | Layer | Notes |
|-----------|-------|-------|
| `let` / `fun` / `match` / `if` | L2 pure | No snapshot mid-reduction |
| `par` / `join` | L3 sugar + frames | Structured concurrency |
| `confirm` | L3 host / Human effect | Freezes `par` pool |
| `try` / `catch` or `Result` | L2 (+ catch frames) | Catchable host errors |
| Agent tool loop | L3 state machine | Like hwfi agent `Current` |
