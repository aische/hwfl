# semantic-check (M8 dogfood)

Deterministic semantic review (**layers 0–2b**) written **in hwfl**, not as a
fan-out of micro-tools.

Workspace = target project under review. The checker module lives in this
directory and is executed with `--workspace` pointed at the project to scan.

## Layers

| Layer | What                                                                           |
| ----- | ------------------------------------------------------------------------------ |
| 0     | `fs.find` + `meta.check_module` → structural findings                          |
| 1     | Catalog from checked qnames; prose qname scan via `md.sections` + `text.words` |
| 2     | `text.metrics` / `text.similarity` → entropy outliers + redundancy pairs       |
| 2b    | `text.split_sentences` + directive heuristics → speech-act hints               |

Always writes `.hwfl/runs/<run-id>/semantic-report.json` in the workspace
(valid JSON via `json.encode`) and returns `{ report_path, ok, finding_count }`.
No API keys required.

## Run

```bash
cabal run hwfl -- run examples/semantic-check/workflows/main.md \
  --workspace path/to/target \
  --input entry=workflows/main \
  --llm-provider mock
```

## Fitness vs hwfi

|                             | hwfi `examples/semantic-check`                     | hwfl (this)                              |
| --------------------------- | -------------------------------------------------- | ---------------------------------------- |
| Author tools / modules      | **74** tool markdown files + 1 workflow + 16 types | **1** module                             |
| Author LOC (tools+workflow) | **~3175**                                          | **~300**                                 |
| Ratio                       | —                                                  | **~10× fewer LOC**, **~75× fewer files** |

Policy and layering stayed; micro-tool staging dissolved into ordinary `fun`s.
