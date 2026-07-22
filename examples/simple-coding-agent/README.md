# simple-coding-agent

Flat one-shot `llm.agent_object` coding agent (skills + FS + `exec.run`).
For the credible chat → FrInvoke session → serial task/verify shape, use
`examples/coding-agent`.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint, effects, skill budgets, `exec.allow` |
| `workflows/main.md` | `llm.agent_object` loop (skills + FS + `exec.run`) |
| `skills/*.md` | Instruction playbooks (python, react, haskell, rust) |
| `sandbox/` | Empty dogfood workspace (optional) |

## Run

```bash
mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/simple-coding-agent \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a pytest that checks add(2,3)==5' \
  --input model=deepseek4flash \
  --llm-provider simple
```

## Check

```bash
cabal run hwfl -- check examples/simple-coding-agent
```
