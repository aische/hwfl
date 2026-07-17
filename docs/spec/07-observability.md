# 07 — Observability

## 1. Problems to fix vs hwfi

- Flat `ctx.trace` lists are hard for humans and agents
- O(n²) “rebuild full trace each step” must not return
- Authors need **tree-shaped** “where did time/money go?”

## 2. Dual channels

| Channel      | File (illustrative) | Role                             |
| ------------ | ------------------- | -------------------------------- |
| **Spans**    | `spans.jsonl`       | Primary UX + agent introspection |
| **Events**   | `events.jsonl`      | Fine-grained audit / debug       |
| **Snapshot** | `snapshot.json`     | Control-flow truth               |

Spans are nested. Events may hang off a span id.

## 3. Span model

```text
Span
  id, parent_id?
  name              # e.g. llm.chat, fs.read, tool:fs_read, user:cluster
  kind              # host | region | module | agent_round | agent_tool
  t_start, t_end?
  status            # ok | error | cancelled
  attrs             # redacted JSON (model, path, token_in, token_out, args?)
  snapshot_seq?     # link to machine seq when host transition
```

Rules:

- Every host op ⇒ span
- Module `main` ⇒ span
- `obs.span("name") { … }` ⇒ region span
- Agent model rounds ⇒ `agent_round` spans; each tool call ⇒ `tool:<name>`
  child span (args summarized/redacted); nested host ops under the tool
- CLI: `hwfl run --debug` streams span open/close; `hwfl show` prints attrs

## 4. Redaction

Same intent as hwfi:

- Secrets never appear in spans/events/snapshots in clear text
- Provider keys never in attrs
- Configurable path scrubbers

## 5. Author APIs

```text
obs.log("info", "clustered", { n = length(xs) })
obs.span("review_gate") { … }
```

## 6. CLI

```text
hwfl show <ws> <run>           # human summary + tree
hwfl show --tree
hwfl show --spans --filter llm
hwfl show --snapshot           # debug machine (redacted)
```

## 7. Agent-facing read APIs

```text
meta.read_spans(run_id, filter?)
meta.read_events(run_id, since_seq?)
```

Do **not** require agents to reconstruct control flow from raw events;
provide span trees and a short textual “cursor” summary derived from the
snapshot (`path` + `current` + `status`).

## 8. Performance constraints

- Append-only span/event writes; O(1) per transition
- Do not rebuild the entire history into RAM each step
- Optional ring buffer of recent spans in memory for ambient queries
