# Turing machine (unary add)

Funny agent stress test: the model must run a tiny Turing machine by
calling only two tools, following a transition table in the system
prompt. Expect token burn and frequent wrong transitions.

## Tape on disk (no JSON)

Workspace paths (seeded from `fixture/`):

| Path | Contents |
|------|----------|
| `machine/state` | Control state (`q0`, `q1`, `q2`, `H`, …) |
| `machine/head` | Unary head index: `N` stars separated by spaces (`""` = 0, `"* *"` = 2) |
| `machine/cells` | Space-separated symbols (`1`, `+`, `_`) |

Tools own the mechanics (extend blanks, move head). The agent only
looks up δ.

| Tool | Role |
|------|------|
| `tm_read` | `{ state, value, halted }` at the head |
| `tm_step` | write symbol, set state, move `L` / `R` / `N`; returns
  `{ ok, halted, error, tape, head, state }` and logs the tape via
  `obs.log` (see run `events.jsonl`; `--debug` for live spans) |

## Instance

Unary add: `11+1` → `111` (2+1=3). Halt state is `H`.

## Run

Deterministic tool self-test (no LLM):

```bash
cabal run hwfl -- check examples/turing-machine
cabal run hwfl -- run examples/turing-machine \
  --workspace /tmp/hwfl-tm \
  --input mode=selftest
```

Agent experiment (will often fail / need `extend`):

```bash
rm -rf /tmp/hwfl-tm && mkdir -p /tmp/hwfl-tm
cabal run hwfl -- run examples/turing-machine \
  --workspace /tmp/hwfl-tm \
  --input mode=agent \
  --input model=deepseek4flash \
  --llm-provider simple
```

Inspect the tape anytime under `$WS/machine/`. On `max_rounds`
exhaustion: `hwfl extend $WS <run-id> --rounds 20`.
