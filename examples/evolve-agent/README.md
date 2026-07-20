# Evolve-agent lab

Non-toy local lab: evolve **coding-agent genomes** on a fixed Python task.

1. Gen 0 scores seed genomes `wasteful` (extra `llm.chat` warmup) vs `tight`
2. LLM proposes an `fs.patch` mutation of the loser (mock proposals fail on
   purpose → **structural fallback** strips the warmup / shrinks `max_rounds`)
3. Next generation = elite + child; repeat for `generations` (default demo: 3)

Fitness: task success (`ok: true` in nested outcome) first, then fewer
`llm.*` spans. Each trial uses an isolated workspace `trials/g{N}/{id}/`.

| Path | Role |
|------|------|
| `workflows/main.md` | Lab parent (score → mutate → iterate) |
| `genomes/tight` | Slim Python coding agent |
| `genomes/wasteful` | Same agent + deliberate warmup chat |
| `fixture/prompt.txt` | Shared coding task |

## Setup + run (mock)

```bash
WS=/tmp/hwfl-evolve-ws
rm -rf "$WS" && mkdir -p "$WS"
cp -R examples/evolve-agent/genomes examples/evolve-agent/fixture "$WS/"
cabal run hwfl -- check examples/evolve-agent
cabal run hwfl -- run examples/evolve-agent --workspace "$WS" \
  --input generations=3 --input model=mock --llm-provider mock
```

Expect `winner:"tight"`, `trial_count:6`, `generations:3`, and
`results.json` under `$WS` with per-trial `task_ok` / `llm_spans` and
mutation events (`via: "fallback"` under mock).

## Live LLM

Same command with a real provider / model. The mutator’s `llm.object` may
apply a real patch (`via: "llm_patch"`); fallback still guards bad hunks.

```bash
cabal run hwfl -- run examples/evolve-agent --workspace "$WS" \
  --input generations=3 --input model=deepseek4flash --llm-provider simple
```
