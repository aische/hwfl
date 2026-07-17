# semantic-check (M8 + deepen)

Semantic review written **in hwfl**, not as a fan-out of micro-tools.

Workspace = target project under review. The checker module lives in this
directory and is executed with `--workspace` pointed at the project to scan.

## Layers

| Layer | What |
| ----- | ---- |
| 0 | Module-tree `fs.find` + `meta.check_module` → structural findings |
| 1 | Catalog from checked qnames; prose qname scan via `text.is_qname` |
| 2 | `text.metrics` / `text.similarity` → entropy outliers + redundancy pairs |
| 2b | `text.split_sentences` + directive heuristics → speech-act hints |
| 3 | Optional same-run `llm.object` on body-bearing `review_gate` items |

Scans `workflows/`, `skills/`, `lib/`, and `types/` only (skips README and
other docs). Always writes `.hwfl/runs/<run-id>/semantic-report.json` in the
workspace (valid JSON via `json.encode`) and returns
`{ report_path, ok, finding_count }`.

Deterministic mode (`mode=deterministic`) needs no API keys. Pragmatic mode
(`mode=pragmatic`) runs gated LLM review in the **same run** and fills
`pragmatic_findings`.

`review_gate` is always emitted (max 8): redundancy / contradiction pairs,
speech-act coverage gaps, and dead-reference prose — with slice bodies for
layer 3. Entropy outliers stay layer-2 info only (not gated). Prose qnames
must match `root/seg…` with roots `workflows|lib|skills|tools|types|builtin`
(after `text.normalize_token`).

## Run

Deterministic:

```bash
cabal run hwfl -- run examples/semantic-check/workflows/main.md \
  --workspace path/to/target \
  --input entry=workflows/main \
  --input mode=deterministic \
  --input model=mock \
  --llm-provider mock
```

Pragmatic (same module; needs a real catalog model unless mocking):

```bash
cabal run hwfl -- run examples/semantic-check/workflows/main.md \
  --workspace path/to/target \
  --input entry=workflows/main \
  --input mode=pragmatic \
  --input model=deepseek4flash
```

## Fitness vs hwfi

| | hwfi `examples/semantic-check` | hwfl (this) |
| --- | --- | --- |
| Author tools / modules | **74** tool markdown files + 1 workflow + 16 types | **1** module |
| Author LOC (tools+workflow) | **~3175** | **~450** |
| Ratio | — | **~7× fewer LOC**, **~75× fewer files** |

Policy and layering stayed; micro-tool staging dissolved into ordinary `fun`s.
Layer 3 stays in-module (no split `semantic-pragmatic` workflow / JSON reload).
