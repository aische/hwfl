# real-story-writer

Multi-chapter story pipeline with **kb-mcp** as the world model.
Distinct from [`examples/story-writer`](../story-writer) (MCP regression
fixture with hard-coded Elara/Harbor seed).

```text
ensure_project(fiction.v1)
  → llm.object Bible → sanitize / regen / minimal → commit
  → llm.object ChapterOutlines (N)
  → for each chapter:
        draft → extract (sanitized) → dry_run/commit
        → extract-only repair → chapter rewrite ×2 → outline regen
        → else record kb_gap (prose kept; no dirty commit)
  → pass-2 over gaps → story/canon.md
```

`strict_kb=true` ⇒ `ok` only when every chapter committed (no gaps).
Default continues with prose complete even if some KB commits lag.

`mode=smoke` skips the LLM and still proves multi-chapter growth + a
planted continuity clash → regen/commit path.

## Prerequisites

1. Build kb-mcp:

```bash
cd ~/code/typescript/2026/kb-mcp   # or your checkout
npm install && npm run build
```

2. Point hwfl at it (optional if `$HOME/code/typescript/2026/kb-mcp` exists):

```bash
export KB_MCP_ROOT=/Users/daniel/code/typescript/2026/kb-mcp
```

## Check

```bash
cabal run hwfl -- check examples/real-story-writer
```

## Run (smoke — no LLM)

```bash
export KB_MCP_ROOT=/Users/daniel/code/typescript/2026/kb-mcp
mkdir -p /tmp/hwfl-real-story
cabal run hwfl -- run --example smoke examples/real-story-writer \
  --workspace /tmp/hwfl-real-story
```

Expect `ok=true`, `contradiction_caught=true`, `chapters_committed=3`.

| Path | Content |
| ---- | ------- |
| `story/bible.md` | Hard-coded Ashport / Mira bible |
| `outlines/chapters.md` | Three chapter outlines |
| `story/ch1.md` … `ch3.md` | Chapter prose |
| `story/ch2-attempt1.md` | Planted-failure marker |
| `story/ch2-findings.json` | AssertResult for dead+located clash |
| `story/canon-after-ch1.md` | Snapshot after chapter 1 |
| `story/canon.md` | Final snapshot (more claims than ch1) |
| `.kb/story.sqlite` | kb-mcp database |

## Run (live — needs provider)

```bash
export KB_MCP_ROOT=/Users/daniel/code/typescript/2026/kb-mcp
mkdir -p /tmp/hwfl-real-story-live
cabal run hwfl -- run examples/real-story-writer \
  --workspace /tmp/hwfl-real-story-live \
  --input mode=live \
  --input model=deepseek4flash \
  --input project_id=real-story-live \
  --input chapters=3 \
  --input strict_kb=false \
  --input premise='Quiet fantasy: a mapmaker inherits a compass that points to unfinished promises. Tone: restrained, coastal. Must-haves: one ally, one harbor town, no grimdark gore.'
```

Empty `premise` in live mode prompts via `human.ask`. Optional `--input title=…`.
Use `--input strict_kb=true` when every chapter must commit to KB for `ok=true`.

| Input | Example | Notes |
| ----- | ------- | ----- |
| `mode` | `smoke` / `live` | smoke needs no LLM |
| `premise` | free text | required for live (or asked) |
| `chapters` | `3` | `< 1` becomes `3` |
| `model` | `deepseek4flash` | from repo `model-catalog.json` |
| `project_id` | `real-story-live` | kb-mcp project (reset each run) |
| `title` | optional | else uses bible title |
| `strict_kb` | `true` / `false` | if true, `ok` requires full KB commit |

Live artifacts mirror smoke, plus per-chapter
`story/ch{N}-findings.json`, optional `story/ch{N}-regen.md`,
`story/bible-regen.md` when the bible was repaired, and
`story/canon-after-ch{N}.md` after each successful commit.

## MCP config

`project.json` spawns kb-mcp with `cwd: workspace`, DB
`.kb/story.sqlite`, profile `workflow` (assert + admin; no agent
`world_*` commit bypass). Continuity packs use `kb_snapshot` (markdown),
not `world_pack`. Override with `KB_MCP_ROOT` / `KB_MCP_DB` /
`KB_MCP_PROFILE`.

## Design locks

- No new hwfl host ops — `mcp.call`, `llm.*`, `fs.*` only
- Ontology: stock `fiction.v1`
- Deltas via `kb_assert_delta`; commit only after clean dry_run
- Claims capped (≤ 12 / chapter); entity slugs not UUIDs
- Layered repair + pass-2; `kb_gap` continues prose without dirty commits
- `strict_kb=true` requires full KB commit for `ok`

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint + `mcp.servers.kb` |
| `types/main.md` | Shared story / KB record aliases |
| `lib/*.md` | KB, claims, bible, extract, chapter, smoke helpers |
| `workflows/main.md` | Live + smoke orchestration + prompts |
| `scripts/run-kb-mcp.sh` | Optional manual launcher |
| `sandbox/` | Empty workspace stub |
