# 13 — MCP client

Normative design for **consuming** external MCP servers from hwfl
workflows and agents. Implementation status: **shipped** (stdio client;
dogfood: `examples/story-writer`, `examples/real-story-writer`).

**Out of scope for this doc / this priority:** exposing hwfl itself as an
MCP server (CLI/run-store façade for Cursor et al.). That remains a
super-low-priority nice-to-have — see [TASKS.md](../TASKS.md).

## 1. Goals

1. Call tools on **local stdio** MCP servers from workflows
   (`mcp.call`) and advertise them to `llm.agent` (`mcp.tools` →
   `List<ToolSpec>`).
2. Dogfood external TypeScript (and other) servers — e.g. a knowledge-base
   MCP with ontology session, web search, filesystem helpers — without
   growing hwfl host ops for each domain.
3. Keep application session state (**handles in arguments / durable
   stores**) separate from MCP **protocol** sessions.

Non-goals (v1): Streamable HTTP / SSE transport; MCP resources / prompts /
sampling / elicitation; `tools/list_changed` hot-reload; embedding a JS
runtime to host servers in-process.

## 2. Protocol notes

- **v1 transport:** stdio only (spawn subprocess; newline-delimited
  JSON-RPC on stdin/stdout; stderr may be logged).
- **Handshake:** implement what the connected server era requires. Older
  revisions use `initialize` / `initialized`; the 2026-07-28 RC removes
  protocol-level sessions for HTTP and makes requests self-describing.
  “MCP is stateless” means **no sticky protocol session** — not “no app
  state.” Workflows that need a KB session still pass `session_id` (or
  bind it client-side) on every tool call.
- Prefer a thin in-tree client (types + stdio + `tools/list` /
  `tools/call`). Do not stretch `exec.run` into a long-lived MCP
  session.

## 3. Configuration (`project.json`)

```json
"mcp": {
  "servers": {
    "kb": {
      "command": "node",
      "args": ["path/to/kb-mcp/dist/index.js"],
      "env": ["PATH", "HOME"],
      "cwd": "workspace"
    },
    "web": {
      "command": "npx",
      "args": ["-y", "@example/mcp-web-search"]
    }
  }
}
```

| Field | Notes |
|-------|-------|
| `mcp.servers.<id>` | Logical server name used by `mcp.call` / `mcp.tools` |
| `command` | Executable basename (same trust model as `exec.allow` — require allowlist or a dedicated MCP allow policy) |
| `args` | Argv |
| `env` | Allowlisted env var names forwarded to the child |
| `cwd` | `"workspace"` (default) \| `"project"` \| absolute path (absolute only if policy allows) |

Missing `mcp.servers` → MCP host ops fail closed at check or run with a
clear error. Spawning an MCP server counts as **`Exec`** (and requires
MCP config present), analogous to `exec.run` needing `exec.allow`.

**Security:** MCP children are **outside** the `fs.*` workspace sandbox.
Command allowlist, env allowlist, and cwd are the real boundary. Document
this next to `exec` policy; do not pretend MCP is sandboxed like `fs.read`.

## 4. Host ops

| Op | Effects | Role |
|----|---------|------|
| `mcp.call` | Exec | Deterministic `tools/call` from workflow code |
| `mcp.tools` | Exec | `tools/list` → `List<ToolSpec>` for `llm.agent` / `llm.agent_object` |
| `mcp.list_tools` | Exec | Optional discovery helper (metadata only); may fold into `mcp.tools` |

### 4.1 `mcp.call`

```text
mcp.call({
  server: String,
  name: String,
  arguments: Json,
  schema?: Schema
}) -[Exec]-> Json   -- or T when schema = schema(T)
```

- Snapshot boundary + span (`mcp.call` / attrs: server, tool name).
- Default result type **`Json`** (MCP content blocks normalized to JSON /
  text then parsed when possible).
- Optional `schema = schema(T)` special-case (same pattern as
  `llm.object` E14): check returns `T`; runtime validates decoded JSON
  against the schema.
- Arguments stay `Json` in v1 (call-site type aliases document the
  contract; optional `arguments_schema` is **[defer]**).

Example (knowledge-base open — workflow only):

```text
type KbOpenOut = { ok: Bool, session_id: String }

let opened : KbOpenOut =
  mcp.call({
    server = "kb",
    name = "kb_open",
    arguments = { session_id = sid, ontology = ontology },
    schema = schema(KbOpenOut)
  })
```

### 4.2 `mcp.tools`

```text
mcp.tools({
  server: String,
  names?: List<String>,
  bind?: Json
}) -[Exec]-> List<ToolSpec>
```

- Lists tools from the server; optional `names` filters the set (omit
  `kb_open` from the agent while still calling it via `mcp.call`).
- Each entry becomes a `ToolSpec` whose callee is an MCP tool reference
  (not a hwfl `fun` / host op). Agent dispatch uses `tools/call`, not a
  nested CEK apply of a typed function.
- Optional `bind`: client merges these fields into every `tools/call`
  arguments object and **strips them from the advertised JSON Schema**
  so the model cannot invent or forget handles (e.g. `session_id`).
- Name collisions across servers: uniquify (e.g. prefix `server__tool`)
  consistently with existing `uniquifyToolNames`.

Example:

```text
llm.agent(
  system = @system,
  prompt = user_prompt,
  tools = mcp.tools({
    server = "kb",
    names = ["kb_store", "kb_retrieve"],
    bind = { session_id = opened.session_id }
  }) ++ [tool(fs.read), tool(exec.run)],
  model = model
)
```

`tool(f)` remains for typed hwfl functions / host ops. MCP tools enter the
agent toolbox via `mcp.tools` (or an equivalent projection), not by
pretending the TypeScript server exports hwfl types.

## 5. Runtime lifecycle

| Concern | Rule |
|---------|------|
| Process | One subprocess per configured server id per **run** (lazy on first use) |
| Resume | Snapshots store server id + tool name + bind metadata — **not** process handles. Reconnect / re-handshake lazily; next MCP call fails clearly if reconnect fails |
| App session | Durable state lives in the external server’s store (or args). Protocol reconnect must not imply “session lost” if `session_id` is stable |
| Errors | Tool-level `isError` / failed content → recoverable tool / call error (agent soft-land); process crash → host error with closed span |
| Teardown | Kill process group when the run completes or the runtime shuts down |

## 6. Agent integration

- `startToolCall` recognizes MCP callees: pass JSON args (after bind
  merge), `tools/call`, map result to tool content string, `completeToolCall`.
- MCP tool callees reuse the same one-shot host-op apply path as
  `tool(fs.read)` (span + persist checkpoint); there is no separate
  CEK evaluation loop for the tool body.
- Spans: keep `tool:<name>`; attrs may include `mcp.server`.
- Synthetic agent tools (`submit`, `get_history`, `pin`, …) unchanged.

## 7. Effects and checking

- `mcp.*` requires **`Exec`** and a non-empty `mcp.servers` entry for the
  named server.
- Modules that only *mention* MCP in prose are unaffected; calling
  `mcp.call` / `mcp.tools` is checked like other host ops.
- Prefer MCP (or in-language modules) over new domain host ops when the
  capability exists as an external server.

## 8. Acceptance (v1)

1. [x] Fake stdio MCP server in tests: list + call round-trip.
2. [x] `mcp.call` from a workflow with and without `schema(T)`.
3. [x] `llm.agent` with `mcp.tools` — mock provider issues a tool call; result
   appears in transcript.
4. Resume after snapshot with MCP tools still advertised; reconnect works
   or fails closed without corrupting the machine.
5. [x] Dogfood path documented: external kb-mcp via `project.json`
   (`examples/story-writer`, `examples/real-story-writer`).

## 9. Deferred

- HTTP / Streamable HTTP client (including 2026-07-28 header/`_meta` era)
- Resources, prompts, sampling, elicitation
- `notifications/tools/list_changed`
- Auto-merge all configured servers into every agent (explicit
  `mcp.tools` / lists first)
- hwfl **as** MCP server (expose check/run/approve to Cursor) — see
  TASKS Future
