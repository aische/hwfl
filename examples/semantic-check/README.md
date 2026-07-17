# semantic-check (M8 + deepen + S2 + S1)

Semantic review written **in hwfl**, not as a fan-out of micro-tools.

Workspace = target project under review. The checker module lives in this
directory and is executed with `--workspace` pointed at the project to scan.

## Layers

| Layer | What |
| ----- | ---- |
| 0 | Module-tree `meta.check_module` → structural findings |
| 1 | Prose qnames via `text.is_qname` + catalog |
| 2 | Entropy info; **within-slice quoted sentence redundancy** (cap 16) |
| 2b | Speech-act heuristics on agent/system sections |
| 3 | Gated `llm.object`: dead-ref / speech / similarity peers + **policy
      slices** (`skills/*`, system/rules) with `check_internal_conflict`;
      same calls extract **obligations** (`must`/`should`/`may`/`must_not`)
      and assign an **illocutionary role** |
| 3a | **Role typing** (S1): forced role per gated slice
      (`System`/`Policy`/`Procedure`/`Example`/`Rationale`/`ToolDoc`);
      quoted `mismatched_sentences`; deterministic Policy/System and
      Example felicity (`category: role`) |
| 3b | **Obligation graph** (S2): deterministic checks on extracted set —
      must∧must_not, system must vs skill may/should, catalog-missing
      objects; policy gates only; ≤4 obs/slice, ≤12 graph rows; finding
      caps 4; quoted evidence |

Scans `workflows/`, `skills/`, `lib/`, and `types/` only. Gate ≤ 8 items.
Deterministic mode needs no API keys. Pragmatic mode fills
`pragmatic_findings` (quoted contradictions + role + obligation-graph
findings) and reports `roles` / `obligations` extracted from gated slices.

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

Pragmatic (same module; real catalog model unless mocking):

```bash
cabal run hwfl -- run examples/semantic-check/workflows/main.md \
  --workspace path/to/target \
  --input entry=workflows/main \
  --input mode=pragmatic \
  --input model=deepseek4flash
```

## Fitness vs hwfi

| | hwfi | hwfl (this) |
| --- | --- | --- |
| Author tools / modules | **74** + workflow | **1** module |
| Policy | micro-tools | ordinary `fun`s + gated LLM |

Layer 3 stays in-module (no split pragmatic workflow / JSON reload).
