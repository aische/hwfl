# Status

Last updated: 2026-07-15

## Current focus

**M0 complete** — Cabal package, kernel AST/parser/pretty, markdown module
loader, golden parse tests. Next: **M1** pure evaluator.

## Done recently

- Scaffolded `pml` Cabal package (GHC2021, lib + `pml` exe + hspec suite)
- Kernel AST + megaparsec parser + pretty (types, patterns, expressions, decls)
- Markdown loader: YAML frontmatter, H2/H3 sections + slugify, one `pml` fence
- 24 parser/load/pretty tests green; `examples/summarise.md` loads via `pml parse`

## Blockers

None.

## Next up

1. **M1** — Pure evaluator (CEK / frames) + unit tests from example suite § pure
2. Later bootstrap (not M0): wire `llm-simple` behind `LlmProvider` (M4)

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
