# coding-agent

Universal coding agent written in hwfl. Point `--workspace` at an empty
directory (or an existing project) and pass a natural-language `prompt`. The
agent inspects the tree, creates/edits files, runs allowlisted build/test
commands, and returns a structured result.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint + `exec.allow` for common toolchains |
| `workflows/main.md` | `llm.agent_object` loop with FS + `exec.run` tools |
| `sandbox/` | Empty dogfood workspace (optional) |

The agent module lives here; the **target project** is the `--workspace`
directory (same pattern as `semantic-check`).

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
  --input prompt='Create a minimal Vite React+TypeScript app with a Hello page and npm test or build that passes' \
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
implement a feature. The agent starts with `fs.list` / `fs.find`.

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
