# `llm` — models

**Effect:** `Net`. Every call is a durable transition. `model` is a
`modelConfigName` from `model-catalog.json` (not a raw vendor id).

Provider failures (auth, rate limit, timeout) are catchable.

## `llm.chat`

**Signature:** `{ system: String, prompt: String, model: String } -> String`

```hwfl
llm.chat(
  system = @system,
  prompt = $"Summarise:\n\n{contents.text}",
  model = "deepseek4flash"
)
```

All three fields are required.

## `llm.chat_messages`

**Signature:** `{ system: String, messages: List<{ role: String, content: String }>, model: String } -> String`

Text-only history. Roles are strings such as `"user"` and `"assistant"`.
For tool-inclusive transcripts use `llm.agent` and `List<Turn>`.

```hwfl
llm.chat_messages(
  system = @system,
  messages = [
    { role = "user", content = "Hi" },
    { role = "assistant", content = "Hello" },
    { role = "user", content = "Go on" }
  ],
  model = "deepseek4flash"
)
```

## `llm.object`

**Signature:** `{ prompt: String, schema: Schema, model: String } -> T`

When `schema = schema(T)`, the result is `T`. Otherwise `Json`.

```hwfl
type Out = { summary: String, score: Int }

let out = llm.object(
  prompt = "Score this note",
  schema = schema(Out),
  model = "deepseek4flash"
)
out.score
```

Attach field descriptions with a `## schema Out` markdown section
([types](../types.md)).

## `llm.agent`

**Signature:**

```text
{
  system: String,
  prompt: String,
  tools: List<ToolSpec>,
  model: String,
  max_rounds?: Int,                 -- default 8
  history?: List<Turn>,             -- seed; prompt appends as a user turn
  context_window?: Int,             -- L1; see agent context
  max_tool_result_chars?: Int,      -- default 16000 when windowing
  consolidate?: String,             -- omit / "off" / "heuristic" / "manual"
  max_pins?: Int,                   -- default 32
  max_summary_chars?: Int           -- default 2000
} -> { text: String, rounds: Int, history: List<Turn> }
```

Named arguments required. `text` is the final assistant reply. `history`
includes this call’s assistant and tool turns (durable snapshot truth).

```hwfl
let result = llm.agent(
  system = @system,
  prompt = user,
  tools = [
    tool(fs.list),
    tool(fs.read),
    tool(fs.write)
  ],
  model = "deepseek4flash",
  history = history,
  max_rounds = 6,
  context_window = 4,
  consolidate = "heuristic"
)
result.text
result.history
```

Windowing, pins, and `get_history`: [agent context](llm-context.md).

If the model hits `max_rounds` without finishing, the run pauses for
`hwfl extend --rounds N`.

## `llm.agent_object`

Same optional fields as `llm.agent`, plus required `schema`.

**Returns:** `{ value: T, rounds: Int, history: List<Turn> }` when
`schema = schema(T)`.

The host injects a synthetic **`submit`** tool. The model must call
`submit` alone (not mixed with other tools in the same round) with a
payload matching the schema.

```hwfl
type Result = {
  summary: String,
  ok: Bool,
  stack: String,
  files_written: List<String>,
  verify_exit: Int
}

let result = llm.agent_object(
  system = @system,
  prompt = inputs.prompt,
  tools = [
    tool(fs.list),
    tool(fs.read),
    tool(fs.write),
    tool(exec.run)
  ],
  schema = schema(Result),
  model = inputs.model,
  max_rounds = 32
)
result.value.ok
```

User functions can be tools too: `tool(search)` where `search` is a
top-level `fun`.

## Tools inside an agent

`tool(fs.read)` is shown to the model as `fs_read`. Write prompts using
those underscored names. Skills, MCP tools, and library functions follow
the same sanitising (`lib/foo.bar` → `lib_foo_bar`).

`skill.discover` / `skill.load` are **not** auto-injected. Put them in
`tools = […]` when the agent should use them.

## Catalog and credentials

`model-catalog.json` lists named configs (`modelConfigName`, provider,
pricing, `maxTokens`, timeouts). Default path is `./model-catalog.json`;
override with `--model-catalog`. The `simple` provider reads API keys
from the environment / `.env` (not from `project.json` `env`).

`--llm-provider mock` needs no network or catalog. `--llm-provider simple`
is the default on `run`.
