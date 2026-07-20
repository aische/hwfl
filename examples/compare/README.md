# Compare lab (local genetic / compare prototype)

Parent workflow materializes N candidate **projects** and per-trial
**workspaces**, scores from outcome + LLM span count, **mutates** the
costlier genome (`rich` → `stripped` via `fs.patch`), then re-runs an
elite + mutant generation.

| Genome | Intent |
|--------|--------|
| `lean` | one `llm.object` call (seed) |
| `rich` | `llm.chat` then `llm.object` (seed; deliberately costlier) |
| `stripped` | gen-1 mutant of `rich` with the draft chat removed |

Same I/O contract; ranking prefers feasible trials with fewer `llm.*` spans.
Under mock, gen 0 picks `lean`; after mutation both elite and `stripped`
are lean-cost; final winner stays `lean` (stable tie).

## Setup

Seed genomes + fixture into the workspace (paths are sandbox-relative):

```bash
WS=/tmp/hwfl-compare-ws
rm -rf "$WS" && mkdir -p "$WS"
cp -R examples/compare/genomes examples/compare/fixture "$WS/"
cabal run hwfl -- check examples/compare
cabal run hwfl -- run examples/compare --workspace "$WS" --llm-provider mock
```

Writes `candidates/`, `trials/`, `genomes/stripped/`, and `results.json`
under `$WS`. Winner should be `lean`; `trial_count` is 4 (two generations).
