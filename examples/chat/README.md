# Chat demo

Workflow-owned chat: recursive `turn(history)` with `human.ask` and
`llm.chat_messages`. Type `/quit` to end. The previous assistant reply is
embedded in the next ask `detail` so CLI / server can show it from
`PauseInfo` alone.

```bash
cabal run hwfl -- check examples/chat
cabal run hwfl -- run examples/chat \
  --workspace /tmp/hwfl-chat \
  --interactive \
  --llm-provider mock
```

Without `--interactive`, each ask pauses (exit `3`); resume with
`hwfl reply <ws> <run-id> --text "…"`.
