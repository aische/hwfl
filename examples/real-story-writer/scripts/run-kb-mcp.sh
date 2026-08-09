#!/usr/bin/env bash
# Optional local launcher (same logic as project.json mcp.servers.kb args).
# Prefer configuring KB_MCP_ROOT in the environment; hwfl spawns via project.json.
set -euo pipefail

ROOT="${KB_MCP_ROOT:-}"
if [[ -z "${ROOT}" ]]; then
  for candidate in "${HOME}/code/typescript/2026/kb-mcp"; do
    if [[ -f "${candidate}/dist/cli.js" ]]; then
      ROOT="${candidate}"
      break
    fi
  done
fi

if [[ -z "${ROOT}" || ! -f "${ROOT}/dist/cli.js" ]]; then
  echo "real-story-writer: set KB_MCP_ROOT to a built kb-mcp checkout (need dist/cli.js)" >&2
  exit 1
fi

DB_PATH="${KB_MCP_DB:-.kb/story.sqlite}"
PROFILE="${KB_MCP_PROFILE:-workflow}"
mkdir -p "$(dirname "${DB_PATH}")"
exec node "${ROOT}/dist/cli.js" serve --db "${DB_PATH}" --profile "${PROFILE}"
