# coding-agent

Universal coding agent written in hwfl. Point `--workspace` at an empty
directory (or an existing project) and pass a natural-language `prompt`. The
agent discovers stack **skills**, inspects the tree, creates/edits files, runs
allowlisted build/test commands, and returns a structured result.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint, effects, skill budgets, `exec.allow` |
| `workflows/main.md` | `llm.agent_object` loop (skills + FS + `exec.run`) |
| `skills/*.md` | Instruction playbooks (python, react, haskell, rust) |
| `sandbox/` | Empty dogfood workspace (optional) |

The agent module lives here; the **target project** is the `--workspace`
directory (same pattern as `semantic-check`).

## Skills

Stack guidance lives under `skills/` as **instruction** skills. The agent
lists `skill.discover` / `skill.load` explicitly (no auto-injection). Typical
sequence: discover by query → load `skills/python-pytest` (or react / haskell /
rust) → write files → verify.

| Skill | Tags |
| ----- | ---- |
| `skills/python-pytest` | python, pytest |
| `skills/react-vite` | react, typescript, vite |
| `skills/haskell-cabal` | haskell, cabal |
| `skills/rust-cargo` | rust, cargo |

## Run (create from empty)

```bash
mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/coding-agent \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a pytest that checks add(2,3)==5' \
  --input model=deepseek4flash \
  --llm-provider simple
```

TypeScript / React:

```bash
cabal run hwfl -- run examples/coding-agent \
  --workspace /tmp/hwfl-react \
  --input prompt='Create a minimal Vite React+TypeScript app with a Hello page and npm build that passes' \
  --input model=deepseek4flash \
  --llm-provider simple
```

Haskell:

```bash
cabal run hwfl -- run examples/coding-agent \
  --workspace /tmp/hwfl-hs \
  --input prompt='Create a small cabal library with add :: Int -> Int -> Int and a tasty/HUnit test' \
  --input model=deepseek4flash \
  --llm-provider simple
```

Local empty sandbox:

```bash
cabal run hwfl -- run examples/coding-agent \
  --workspace examples/coding-agent/sandbox \
  --input prompt='…' \
  --input model=deepseek4flash \
  --llm-provider simple
```

## Fix an existing project

Same command; point `--workspace` at the project and ask to repair tests /
implement a feature. The agent starts with discover/load + `fs.list` /
`fs.find`.

## Exec policy

`project.json` allowlists common basenames (`python3`, `npm`, `cabal`, …) and
sets `exec.confirm` to `false` so demos and CI are non-interactive. For
operator approval before each spawn, set `"confirm": true` and use
`hwfl approve`.

Child processes run with cwd = workspace and only the listed env keys
(`PATH`, `HOME`, …).

## Check

```bash
cabal run hwfl -- check examples/coding-agent
```
