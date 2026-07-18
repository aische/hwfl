# 06 — Runtime (interpreter, resume, par, confirm)

## 1. Goals

1. Exact resume after crash/abort/pause
2. Operator `--step` (one transition)
3. Bounded `par` pool with ordered results (**shipped:** cooperative
   scheduler; **future:** concurrent host IO — §10)
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

On `continue` / `resume` / `approve`:

1. Reload entry module from `meta.rmEntry`
2. Recompute `project_hash` the same way as start:
   - **Project run:** walk parents of the entry path for `project.json`
     (max 32); hash = `projectHashForModules` over `loadProject`; skill
     catalog from that project root (so control-plane layouts with a
     separate project dir vs workspace tip still resolve).
   - **Lone module** (no project root): hash = `projectHashOf` entry;
     skills from the workspace root.
3. Refuse if hash ≠ snapshot `rsProjectHash` (stale project)
4. Restore machine from snapshot; schedule next transition

Stale project hash ⇒ refuse (or require new run). No silent Merkle
auto-skip of work (hwfi abandoned cache-as-resume).

**Pinning rule:** `runTargetProject` stores `projectHashForModules`;
`runTargetModule` stores `projectHashOf`. Resume must not recompute the
entry-only hash for a project-shaped run — that always mismatches.

## 5. `par` policy

```text
par(max = N, on_error = fail|collect) for x in xs { body }
```

Semantics:

- Cap concurrent **active** branches at `N` (default 4).
- Result order = input order.

**Current implementation (M5):** cooperative pool — up to `N` branch
machines may be active, but the driver runs **one branch transition**
at a time. Blocking host ops (LLM HTTP, `fs.read`, …) therefore do not
overlap across branches. Confirm freeze, ordered slots, and resume of
`FrPar` / `BranchMachine` are implemented and tested.

**Future (§10):** overlap blocking host work without changing surface
semantics.
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

**Skills:** mid-loop `skill.load` may expand the active tool set (callable)
or append instruction context (rebuild-from-ids on resume). Checkpoints
persist `active_tool_ids` / `loaded_instruction_ids`. Agent tool spans
appear as `tool:skill_discover` / `tool:skill_load` under the enclosing
agent round. See [skills-plan.md](../skills-plan.md).

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

## 10. Concurrent host transitions in `par` (future, nice-to-have)

**Goal:** wall-clock overlap when several branches are blocked on host
IO, without changing `par` language semantics or snapshot/resume shape.

**Non-goals:** user-visible threads; parallel pure reduction; rewriting
the LLM provider as non-blocking IO.

### 10.1 Terminology

Three schedulers stack on top of each other:

| Layer | Role |
| ----- | ---- |
| hwfl `par` pool | Structured concurrency: `BranchMachine` per slot, confirm drain, ordered join |
| GHC lightweight threads | `async` / `forkIO` at host boundaries (if adopted) |
| OS capabilities (`-N`) | Only needed for CPU-bound overlap; I/O-bound `par` usually needs layer 2 only |

M5 deliberately shipped layer 1 only (cooperative stepping).

### 10.2 Recommended approach

Keep a **single coordinator** that owns `RunCtx`, span stack, snapshot
seq, and `ParJoinState`. At `CurHost` on a branch:

1. Open spans on the coordinator (per-branch parent, e.g. slot index).
2. Submit `runHostOp` / provider IO to a worker (`async`).
3. Mark slot in-flight; do not block the coordinator on the worker.
4. On completion: close span, absorb result into `ParJoinState`, persist
   one transition, continue scheduling.

Pure crunch stays on the coordinator (big-step until next host boundary).

### 10.3 Policies to decide before shipping

- **`--step` / `StepOnce`:** cap in-flight host work to 1 (deterministic
  stepping) vs allow parallel (faster but non-deterministic step
  boundaries).
- **Confirm drain:** wait for in-flight host IO to finish (no cancel
  today); same semantics as §5.1 but with real blocking waits.
- **Spans:** global `SpanState` is not thread-safe — coordinator-only
  mutation, or per-branch span stacks merged on completion.
- **Snapshot seq:** interleaved branch completions get monotonic seq
  numbers; ordering rule must be deterministic.
- **Crash mid-host-op:** at-least-once re-run per branch (possibly
  several in-flight); document duplicate LLM cost.
- **`on_error = fail`:** drain in-flight vs cancel siblings.
- **Same-path `fs.write` in `par`:** undefined / warn / lock.

### 10.4 Acceptance sketch

- `par(max = 2)` over three mock-slow LLM or `fs.read` calls finishes
  faster than sequential when not stepping.
- Existing E07 par-confirm, step/resume, stale-hash tests stay green.
- `hwfl step` behaviour documented and stable.
