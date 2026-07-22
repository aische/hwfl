# coding-agent

Credible **skill-driven** coding agent. Chat owns the human loop; the
language owns plan → serial implement → verify. LLMs fill holes.

```text
chat (human.ask + history)
  └─ tool: coding_session(prompt)     # FrInvoke → workflows/coding
        ├─ gather_context             # read-only pre-pass
        ├─ plan → List<Task>          # agent_object + skill.*
        └─ for task in tasks
              ├─ do_task(task)        # agent_object + skill.* + FS
              └─ verify(task)         # FrInvoke → workflows/verify
                    └─ fail → one retry → stop
```

Chat does **not** list `fs.write`. Edits go through `coding_session`.
Planner and coder advertise `skill.discover` / `skill.load`. Verifier is a
non-agent workflow.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint `workflows/main`, effects, skill budgets, `exec.allow` |
| `workflows/main.md` | Multi-turn chat; tools `gather_context` + `coding_session` |
| `workflows/coding.md` | Session: context → plan → serial do_task / verify |
| `workflows/gather_context.md` | Read-only list/find/grep/read under a token budget |
| `workflows/verify.md` | `exec.run` wrapper → `{ exit, stdout, stderr, ok }` |
| `skills/*.md` | Instruction playbooks (python, react, haskell, rust) |
| `sandbox/` | Empty dogfood workspace (optional) |

Flat one-shot `llm.agent_object` (no chat / no typed task loop) lives in
`examples/simple-coding-agent`.

## Skills

| Skill | Tags |
| ----- | ---- |
| `skills/python-pytest` | python, pytest |
| `skills/react-vite` | react, typescript, vite |
| `skills/haskell-cabal` | haskell, cabal |
| `skills/rust-cargo` | rust, cargo |

## Interactive chat

```bash
cabal run hwfl -- run --interactive examples/coding-agent \
  --workspace /tmp/hwfl-build \
  --llm-provider simple
```

Type at `You>`; `/quit` ends. Ask the assistant to implement something — it
should call `coding_session`. For read-only questions it can call
`gather_context`.

## Non-interactive coding session

Bypass chat and run the session entry directly:

```bash
mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/coding-agent/workflows/coding.md \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a pytest that checks add(2,3)==5' \
  --input model=deepseek4flash \
  --llm-provider simple
```

TypeScript / React, Haskell, and local sandbox: same pattern with a different
`--workspace` / prompt (see `examples/simple-coding-agent` for more prompt
examples).

## Exec policy

`project.json` allowlists common basenames and sets `exec.confirm` to
`false` for demos. Set `"confirm": true` and use `hwfl approve` for gated
spawns.

## Check

```bash
cabal run hwfl -- check examples/coding-agent
```
