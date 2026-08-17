# Agent context

Applies to `llm.agent` and `llm.agent_object`. Full `history` /
`agHistory` remains snapshot and resume truth. These knobs only change
what is **sent to the provider**.

## L1 — `context_window`

Optional `context_window = N` sends only the last **N user turns** plus
their follow-on assistant/tool turns.

When windowing is on, a read-only **`get_history`** tool is injected.
`chunk = 0` is the most recent hidden page, then `1`, `2`, ….

Optional `max_tool_result_chars` caps tool payloads on the **wire** view
(default **16000** when `context_window` is set). Durable history keeps
full content.

## L2 — `consolidate`

| Value | Behaviour |
|-------|-----------|
| omit / `"off"` / `"false"` / `""` | No auto compact; no `pin` / `consolidate` tools |
| `"heuristic"` | Requires `context_window`. Before each model round, fold the droppable prefix into pins + a short summary; inject `pin` and `consolidate` tools |
| `"manual"` | Inject `pin` / `consolidate` only (no automatic fold). Pins still assemble ahead of the wire view |
| `"llm"` | **Not implemented** — rejected at run |

Wire assemble order: pins block + optional earlier-context summary, then
the L1 window (capped tool results). `max_pins` (default **32**) and
`max_summary_chars` (default **2000**) bound retained memory.

Pins / summary / watermark live on in-flight agent state for **one**
`llm.agent` call. Re-entering with only `history` (chat-style outer loop)
rebuilds heuristic memory cheaply; it does **not** carry explicit pins
across human turns.

## Prompting

Tell the model when these tools exist:

```text
Earlier turns may be outside your context window — call get_history(chunk=0)
(then 1, …) if you need them. Pin durable facts with pin when they matter.
```
