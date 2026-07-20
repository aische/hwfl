# Evolve-agent lab

Evolve **coding-agent genomes** on a seeded broken Python package
(`fixture/project`: buggy `stats.py` + failing tests).

1. Gen 0 scores `wasteful` (warmup `llm.chat`) vs `tight` on the same fixture
2. Mutate the loser with an **operator menu**:
   `strip_warmup` | `shrink_rounds` | `drop_fs_list`
3. LLM proposes `fs.patch` hunks; **no-op patches are rejected**; structural
   fallbacks try operators in gen-rotated order until the genome bytes change
4. Next population = elite + child; repeat for `generations` (demo: 3)

Fitness: nested outcome `ok` first, then fewer `llm.*` spans. Trials use
isolated workspaces `trials/g{N}/{id}/` (fixture copied in each time).

| Path | Role |
|------|------|
| `workflows/main.md` | Lab parent |
| `genomes/tight` | Slim fix-oriented coding agent |
| `genomes/wasteful` | Same + deliberate warmup chat |
| `fixture/prompt.txt` | Task instructions |
| `fixture/project/` | Broken package under test |

## Setup + run (mock)

```bash
WS=/tmp/hwfl-evolve-ws
rm -rf "$WS" && mkdir -p "$WS"
cp -R examples/evolve-agent/genomes examples/evolve-agent/fixture "$WS/"
cabal run hwfl -- check examples/evolve-agent
cabal run hwfl -- run examples/evolve-agent --workspace "$WS" \
  --input generations=3 --input model=mock --llm-provider mock
```

Expect `winner:"tight"`, `trial_count:6`. Inspect `$WS/results.json` for
`mutations[].operator` / `via`, and confirm `mut-g0` ≠ `mut-g1` on disk.

## Live LLM

```bash
cabal run hwfl -- run examples/evolve-agent --workspace "$WS" \
  --input generations=3 --input model=deepseek4flash --llm-provider simple
```

Real models may apply `via: "llm_patch"`; no-op or bad hunks still fall through
to the operator fallbacks.
