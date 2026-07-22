# coding-agent

Credible **skill-driven** coding agent. Chat owns the human loop; the
language owns plan → serial implement → verify. LLMs fill holes.

```text
chat (human.ask + history)
  └─ tool: coding_session(prompt)     # FrInvoke → workflows/coding
        ├─ gather_context             # read-only pre-pass (inside session)
        ├─ plan → List<Task>          # agent_object + skill.*
        └─ for task in tasks
              ├─ do_task(task)        # agent_object + skill.* + FS + exec
              └─ verify(task)         # FrInvoke → workflows/verify
                    └─ fail → one retry → stop
```

Chat advertises **only** `coding_session` (no peer read tool). Context survey
stays inside `workflows/coding`. Planner loads skills and emits install/build
gates; the doer has FS + `exec.run` (so it can `npm install`); outer verify
re-checks each task. Planner/coder use `skill.*`.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint `workflows/main`, effects, skill budgets, `exec.allow` |
| `workflows/main.md` | Multi-turn chat; sole tool `coding_session` |
| `workflows/coding.md` | Session: context → plan → serial do_task / verify |
| `workflows/gather_context.md` | Stack-scoped survey; skips finds on empty workspace; drops `node_modules`/build trees |
| `workflows/verify.md` | `exec.run` wrapper → `{ exit, stdout, stderr, ok }` |
| `skills/*.md` | Instruction playbooks (python, react, haskell, rust) |
| `sandbox/` | Empty dogfood workspace (optional) |

Flat one-shot `llm.agent_object` (no chat / no typed task loop) lives in
`examples/simple-coding-agent`.

## Skills

| Skill | Tags |
| ---- | ---- |
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

Type at `You>`; `/quit` ends. Ask to implement something — chat should call
`coding_session` (plans, writes, verifies). One-shot without chat: use
`examples/simple-coding-agent`.

## Exec policy

`project.json` allowlists common basenames and sets `exec.confirm` to
`false` for demos. Set `"confirm": true` and use `hwfl approve` for gated
spawns.

## Check

```bash
cabal run hwfl -- check examples/coding-agent
```
