# `mcp` — stdio client

**Effect:** `Exec`. Durable. Requires `project.json` `mcp` with a named
server and a command allowlist (same trust model as `exec.allow`: bare
basenames).

MCP children are **outside** the `fs.*` sandbox. The boundary is the
command allowlist plus `cwd` policy.

## `mcp.call`

**Signature:** `{ server: String, name: String, arguments: Json | record, schema?: Schema } -> Json`

When `schema = schema(T)`, the result is `T`. Use for deterministic tool
RPCs.

```hwfl
mcp.call(
  server = "kb",
  name = "search",
  arguments = { q = "plot hole" },
  schema = schema(Hit)
)
```

## `mcp.tools`

**Signature:** `{ server: String, names?: List<String>, bind?: Json | record } -> List<ToolSpec>`

Build an agent toolbox from a server. `names` filters the advertised
tools. `bind` injects hidden arguments (for example a `session_id`) that
the model does not fill.

```hwfl
let kb = mcp.tools(server = "kb", names = ["search", "write"])
llm.agent(
  system = @system,
  prompt = user,
  tools = kb,
  model = "deepseek4flash"
)
```

## `project.json`

```json
"mcp": {
  "allow": ["bash", "node", "npx"],
  "allow_absolute_cwd": false,
  "servers": {
    "kb": {
      "command": "bash",
      "args": ["-c", "…"],
      "cwd": "workspace",
      "env": ["PATH", "HOME"],
      "timeout_ms": 30000
    }
  }
}
```

| Field | Meaning |
|-------|---------|
| `allow` | Basename allowlist; every `servers.*.command` must be in it |
| `allow_absolute_cwd` | Default `false`. Absolute `cwd` is rejected unless `true` |
| `servers.*.command` | Bare basename |
| `servers.*.args` | Argument vector |
| `servers.*.cwd` | `"workspace"` (default), `"project"`, or an absolute path |
| `servers.*.env` | Parent env keys forwarded |
| `servers.*.timeout_ms` | Optional positive per-request timeout |

`command` with `/` or `\` is rejected at project load.
