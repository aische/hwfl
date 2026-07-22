# hwfl

Durable workflow **runtime** (Haskell library + CLI). Programs are typed
markdown modules: prose and an ML-ish kernel share one file. LLM calls,
filesystem, `exec`, parallelism, and human confirm are host effects with
checkpointed resume.

## Why

Agentic systems usually bury prompts in host-language glue, or use a thin
step DSL that falls over when real computation shows up. hwfl keeps
document-shaped authoring and a small general-purpose language in one
module, then runs it durably and observably.

## Example

`examples/coding-agent` is the credible skill-driven coding agent: chat
(`human.ask`) delegates edits via a `coding_session` tool (`FrInvoke` →
typed plan → serial implement/verify). Flat one-shot `llm.agent_object`
lives in `examples/simple-coding-agent`.

```bash
cabal build hwfl
cabal run hwfl -- check examples/coding-agent

# Interactive chat (type at You>; /quit to end)
cabal run hwfl -- run --interactive examples/coding-agent \
  --workspace /tmp/hwfl-build \
  --llm-provider simple

# Non-interactive coding session (bypass chat)
mkdir -p /tmp/hwfl-build && rm -rf /tmp/hwfl-build/*
cabal run hwfl -- run examples/coding-agent/workflows/coding.md \
  --workspace /tmp/hwfl-build \
  --input prompt='Create a tiny Python package with add(a,b) and a check' \
  --input model=deepseek4flash \
  --llm-provider simple
```

Needs a configured `model-catalog.json` and provider credentials (see
`.env`). Run state lands under the workspace `.hwfl/runs/<run-id>/`.
More: [examples/coding-agent/README.md](examples/coding-agent/README.md),
[docs/tutorial.md](docs/tutorial.md).

## Layout

| Path | Role |
| ---- | ---- |
| `src/Hwfl/` | Library: parse, check, eval, durable runtime, LLM, observability |
| `app/` | CLI wrapping the driver façade |
| `examples/` | Example modules and projects |
| `docs/` | Spec, architecture, language reference |

## Docs

- [docs/tutorial.md](docs/tutorial.md) — check → run → approve → resume → show
- [docs/language-reference.md](docs/language-reference.md) — surface language
- [docs/architecture.md](docs/architecture.md) — layers and boundaries
- [examples/chat](examples/chat) — workflow chat (`human.ask` + `/quit`)
