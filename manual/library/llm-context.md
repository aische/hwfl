# Agent context

Applies to `llm.agent` and `llm.agent_object`. These knobs only change
what is sent to the model. The returned `history` is complete and is what
you pass into a later call.

## `context_window`

Optional `context_window = N` sends only the last **N user turns** plus
their follow-on assistant/tool turns.

When it is set, a read-only **`get_history`** tool is added. `chunk = 0`
is the most recent hidden page, then `1`, `2`, ….

Optional `max_tool_result_chars` caps tool payloads sent to the model
(default **16000** when `context_window` is set). Full tool results stay
in `history`.

## `consolidate`

| Value | Behaviour |
|-------|-----------|
| omit / `"off"` / `"false"` / `""` | No compacting; no `pin` / `consolidate` tools |
| `"heuristic"` | Requires `context_window`. Before each model round, older turns outside the window are folded into pins plus a short summary; adds `pin` and `consolidate` tools |
| `"manual"` | Adds `pin` / `consolidate` only (no automatic fold). Pins still appear before the windowed turns |

The model sees: pins, then an optional summary of older turns, then the
windowed turns (with capped tool results). `max_pins` (default **32**)
and `max_summary_chars` (default **2000**) bound that extra memory.

Pins and the summary last for **one** `llm.agent` call. Passing only
`history` into a later call does **not** keep explicit pins across
`human.ask` turns.

## Prompting

Tell the model when these tools exist:

```text
Earlier turns may be outside your context window — call get_history(chunk=0)
(then 1, …) if you need them. Pin durable facts with pin when they matter.
```
