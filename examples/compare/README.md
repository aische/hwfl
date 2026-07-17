# Compare lab (local genetic / compare prototype)

Parent workflow materializes N candidate **projects** and per-trial
**workspaces**, then `meta.check_project` → `meta.invoke` → scores from
outcome + LLM span count (proxy for cost under mock).

| Genome | Intent |
|--------|--------|
| `lean` | one `llm.object` call |
| `rich` | `llm.chat` then `llm.object` (deliberately costlier) |

Same I/O contract; ranking prefers feasible trials with fewer `llm.*` spans.

## Setup

Seed genomes + fixture into the workspace (paths are sandbox-relative):

```bash
WS=/tmp/hwfl-compare-ws
rm -rf "$WS" && mkdir -p "$WS"
cp -R examples/compare/genomes examples/compare/fixture "$WS/"
cabal run hwfl -- check examples/compare
cabal run hwfl -- run examples/compare --workspace "$WS" --llm-provider mock
```

Writes `candidates/`, `trials/`, and `results.json` under `$WS`.
Winner should be `lean` under the mock provider.
