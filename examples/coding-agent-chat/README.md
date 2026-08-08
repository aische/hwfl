# coding-agent-chat

Multi-turn `human.ask` loop with `llm.agent` tool history threaded across
turns (not text-only `llm.chat_messages`).

```bash
hwfl run --interactive examples/coding-agent-chat
```

Type messages at `You>`; `/quit` ends the session. Each turn calls
`llm.agent` with the prior transcript (user, assistant+tool calls, tool
results) carried in `history`.

**Context windowing:** `context_window = 4` limits the provider wire view
to the last four user turns (+ follow-ons); full `history` remains the
audit / resume transcript. `consolidate = "heuristic"` folds the
droppable prefix into pins + a short summary before each model round.
Injected tools: `get_history`, `pin`, `consolidate`. Mid-call pins are
not yet threaded across outer `turn`s (only `history` is); that lands
with `consolidate = "llm"` — see docs.
