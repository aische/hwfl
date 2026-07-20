# coding-agent-chat

Multi-turn `human.ask` loop with `llm.agent` tool history threaded across
turns (not text-only `llm.chat_messages`).

```bash
hwfl run --interactive examples/coding-agent-chat
```

Type messages at `You>`; `/quit` ends the session. Each turn calls
`llm.agent` with the prior transcript (user, assistant+tool calls, tool
results) carried in `history`.
