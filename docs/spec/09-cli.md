# 09 — CLI

Executable name provisional: **`hwfl`**.

## 1. Commands (v0)

| Command                                                 | Purpose                                          |
| ------------------------------------------------------- | ------------------------------------------------ |
| `hwfl check <project> [--json]`                                  | Load + type + effects + graph; exit ≠0 on error  |
| `hwfl run <project> [--workspace <dir>] [--input k=v…] [--debug] [--cost] [--json]` | Check (unless `--no-check`) + execute entrypoint |
| `hwfl step <workspace> <run-id>`                        | One transition, then pause                       |
| `hwfl resume <workspace> <run-id>`                      | Continue until end / pause / fail                |
| `hwfl approve <workspace> <run-id> [--yes\|--no]`       | Resolve confirm gate                             |
| `hwfl show <workspace> <run-id> [flags]`                | Spans / status / redacted snapshot               |
| `hwfl version`                                          |                                                  |

### Flags (common)

- `--llm-provider <name>`
- `--json` machine-readable diagnostics on check/run errors
- `-v` / `--verbose` (on `run`): print span tree to stderr after the run
- `--debug` (on `run`): install the stderr live observer (span open/close,
  pause, finish on stderr); implies `--verbose`. Same driver `Observer`
  hook a control plane would use for WS/SSE. When LLM streaming spans
  ship: also show **coalesced** progressive deltas (or compact progress)
  for in-flight `llm.chat` / `agent_round` spans — not one line per
  provider token. See [07-observability.md](07-observability.md) §9.
- `--cost` (on `run`): prefix host progress lines (`fs.read …`,
  `llm.object …`, …) with running LLM spend, e.g. `$0.12 │ fs.read …`.
  Uses the same counter as `--debug` span lines; bumps on priced LLM
  span close.

## 2. Inputs

Prefer:

```bash
hwfl run ./examples/hello --workspace /tmp/ws --input path=README.md
```

Typed coercion from CLI strings per `inputs` types (`FileRef`, `String`,
`Int`, `Bool`, JSON for complex — document).

## 3. Exit codes

| Code | Meaning                                       |
| ---- | --------------------------------------------- |
| 0    | success                                       |
| 1    | check / runtime failure                       |
| 2    | usage error                                   |
| 3    | paused awaiting confirm (optional convention) |
| 4    | stale project / resume refused                |

Exact codes may adjust in M4; stay stable after first release tag.

## 4. Output

- Human logs on stderr
- Primary result JSON on stdout for `run` when `--output json` **[recommend]**
- Spans always on disk under `.hwfl/runs/…`

## 5. Completions / UX

Nice-to-have **[defer]**: shell completions, `hwfl init` scaffold.
