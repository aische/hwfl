# 06 — Runtime (interpreter, resume, par, confirm)

## 1. Goals

1. Exact resume after crash/abort/pause
2. Operator `--step` (one transition)
3. Real bounded parallelism
4. Cooperative confirm freeze inside `par`
5. Pluggable persistence (filesystem first)

Non-goal: replaying the event log as the source of truth.

## 2. Unit of execution — transition

A **transition** is one atomic machine step, typically:

- enter/complete a host op
- one LLM provider call (including one agent model or tool round)
- schedule / join progress for `par`
- enter/leave `confirm` pause
- module invoke enter/return

Pure β-reduction may run **inside** a transition until the next host
boundary (big-step pure, small-step effects). That keeps snapshots small
and performance reasonable.

Crash mid-host-op (e.g. kill during HTTP): that transition is **re-run**
on resume (at-least-once). Host ops should be written with that in mind
(LLM calls may duplicate; document idempotency expectations).

## 3. Machine shape

```text
Machine
  status          running | draining | paused | completed | failed
  project_hash    staleness check
  path            program counter (module + frame address)
  current         optional reducible state (agent round, host in-flight, …)
  frames          continuation stack
  env/bindings    values
  heap            if needed for shared structure
  last_result
  error           optional
```

Frames include at least:

| Frame | Role |
|-------|------|
| `FrSeq` / let-kont | finish `let` / application kont |
| `FrApp` | evaluating args |
| `FrPar` | parallel map/join pool |
| `FrTry` | catch handler |
| `FrConfirm` | waiting human |
| `FrInvoke` | nested module |
| `FrAgent` | tool/model loop |

Prior art: hwfi `Hwfi.Runtime.Machine` and llm-workflow `Stack (Step, Kont)`.

## 4. Snapshots

Persist after each completed transition (or on pause/crash flush):

```text
snapshot_format: 1
run_id, seq, machine_json, at
```

On `continue` / `resume`:

1. Load project; verify `project_hash`
2. Load snapshot
3. Schedule next transition

Stale project hash ⇒ refuse (or require new run). No silent Merkle
auto-skip of work (hwfi abandoned cache-as-resume).

## 5. `par` policy

```text
par(max = N, on_error = fail|collect) for x in xs { body }
```

Semantics:

- Cap concurrent active branches at `N` (default 4).
- Result order = input order.
- `on_error = fail`: abort at lowest index failure after drain? Prefer:
  fail-fast after cooperative drain of in-flight — document.
- `on_error = collect`: per-index `Result` envelopes.

### 5.1 Confirm inside `par`

1. Scheduler stops **starting** new branch transitions
2. In-flight branches finish **current** transition only
3. Status → `draining` then `paused` / `awaiting_confirm`
4. Approve → blocked branch continues; pool resumes

No branch starts a new transition while draining/paused for confirm.

### 5.2 Crash/resume of `par`

`FrPar` stores:

- items list
- per-index slot: pending | running | done | failed | awaiting_confirm
- `active: Map index BranchMachine`
- scheduler cursor + pool phase

Completed iterations are **not** re-run.

## 6. Agent loop

`llm.agent` expands to multiple transitions:

```text
model_call → (tool_call → tool_result →)* → final
```

Each model/tool call is snapshotted. Tools invoke ordinary functions /
host ops under the agent frame.

**Skills (planned):** mid-loop `skill.load` may expand the active tool set
(callable) or append instruction context; checkpoints must record loaded
ids for resume. See [skills-plan.md](../skills-plan.md).

## 7. Workspace & sandbox

Identical intent to hwfi:

- All file ops under workspace root
- Canonicalize + prefix check (no symlink escape)
- Separate project dir (code) vs workspace dir (data) if both provided by CLI

## 8. Determinism

- Pure evaluation deterministic
- `par` scheduling may be nondeterministic in wall-clock order; results
  ordered
- LLM nondeterministic — expected; resume must not invent alternate pure
  history

## 9. Implementation guidance

Prefer a single `stepMachine :: … -> IO (Machine, [SpanEvent])` loop
driven by CLI `run` / `step` / `resume`, matching hwfi’s StepDriver
pattern without the step-DSL AST.
