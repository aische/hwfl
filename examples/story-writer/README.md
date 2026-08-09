# story-writer

Dogfoods hwfl’s **MCP client** against the external kb-mcp stdio server
(sibling checkout `typescript/2026/kb-mcp`): seed a fiction world, catch a
planted continuity contradiction with `kb_assert_delta(dry_run)`, then
commit a clean chapter.

```text
ensure project (fiction.v1)
  → commit bible seed (Elara @ Harbor, alive)
  → dry_run planted dead+located clash → findings
  → commit clean ch2 delta
  → kb_snapshot → story/canon.md
```

`mode=live` adds `llm.chat` + `llm.object` extract with one regen on findings.

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

3. Workspace for prose + SQLite:

```bash
mkdir -p /tmp/hwfl-story
```

## Check

```bash
cabal run hwfl -- check examples/story-writer
```

## Run (fixture — no LLM)

```bash
export KB_MCP_ROOT=/Users/daniel/code/typescript/2026/kb-mcp
cabal run hwfl -- run --example fixture examples/story-writer \
  --workspace /tmp/hwfl-story
```

Expect `ok=true`, `contradiction_caught=true`, and:

| Path | Content |
| ---- | ------- |
| `story/ch2-bad-findings.json` | AssertResult for the planted clash |
| `story/ch2.md` | Clean chapter prose |
| `story/canon.md` | `kb_snapshot` encode |
| `.kb/story.sqlite` | kb-mcp database |

## Run (live — needs provider)

```bash
export KB_MCP_ROOT=/Users/daniel/code/typescript/2026/kb-mcp
cabal run hwfl -- run examples/story-writer \
  --workspace /tmp/hwfl-story-live \
  --input mode=live \
  --input model=deepseek4flash \
  --input project_id=story-live
```

| Input | Example | Notes |
| ----- | ------- | ----- |
| `mode` | `fixture` / `live` | fixture needs no LLM |
| `model` | `deepseek4flash` | from repo `model-catalog.json` |
| `project_id` | `story-demo` | kb-mcp project id (reset each run) |

## MCP config

`project.json` spawns kb-mcp with `cwd: workspace`, DB
`.kb/story.sqlite`, profile `workflow` (admin + assert; no agent
`world_*`). Override with `KB_MCP_ROOT` / `KB_MCP_DB` / `KB_MCP_PROFILE`.

## Layout

| Path | Role |
| ---- | ---- |
| `project.json` | Entrypoint + `mcp.servers.kb` |
| `workflows/main.md` | Fixture + live continuity loop |
| `scripts/run-kb-mcp.sh` | Optional manual launcher |
| `sandbox/` | Empty workspace stub |
| `fixture/prompt.txt` | Spare prompt (live uses `@chapter_prompt`) |
