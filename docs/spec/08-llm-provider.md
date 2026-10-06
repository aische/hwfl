# 08 — LLM provider adapter

## 1. Requirement

v0 ships with **[llm-simple](https://hackage.haskell.org/package/llm-simple)**
(`^>=0.2.0.0`) as the **default** backend, but workflows and most of the
engine must not depend on that package directly.

It must be possible to swap in a more production-ready client (official
SDKs, gateway proxies, retry/backoff middleware, observability hooks)
without changing hwfl modules.

## 2. Interface (`LlmProvider`)

Logical operations (Haskell typeclass or record-of-functions):

```text
chat ;
  messages     : [Message]
  model        : ModelId
  tools?       : [ToolSpec]      -- for agent rounds
  response_fmt?: JsonSchema      -- for structured object mode
  on_chunk?    : StreamDelta → IO ()   -- optional progressive hook
  → IO (Either ProviderError ProviderResult)

embed ;                          -- optional / [defer]
  …
```

`ProviderResult` includes:

- **authoritative** ordered assistant parts (`prParts`)
- derived projections: text (`prContent`) and tool calls (`prToolCalls`)
- usage: input/output tokens plus cache-read / cache-creation counts
- finish reason

Constructors go through a smart constructor so projections cannot
disagree with `prParts`.

`ProviderError`: catchable classification (auth, rate limit, timeout,
invalid request, other). Unsupported model capabilities map to invalid
request with an actionable message.

### 2.1 Message / tool types

Engine-owned ADTs in `Hwfl.Llm.Types` — **not** re-exported llm-simple
types into Eval. Adapters convert both ways.

Assistant history is ordered content, not a separate text + tool-call
pair:

```text
ProviderOpaque     -- provider/model tag + opaque JSON payload
ThinkingContent    -- optional visible text + optional ProviderOpaque
AssistantPart      -- text | thinking | tool_call (with optional meta)
Turn               -- user text | assistant [AssistantPart] | tool results
```

Rules:

- Runtime stores the exact `prParts` returned by the provider after each
  agent round. Tool dispatch and final-answer paths use projections only;
  they must not rebuild or reorder parts.
- Converting an assistant turn back to the provider must preserve part
  order and include opaque thinking / tool-call metadata required for
  Claude and Gemini replay.
- Opaque payloads are **replay state**: persist losslessly in machine
  snapshots; omit from author-facing JSON, transcript formatting, and
  observability events. Do not copy them into tool results.
- Multimodal author surface is out of scope; the adapter boundary should
  still allow a future user-content ADT (e.g. image parts) without another
  assistant-history migration.

### 2.2 Streaming callback

Progressive deltas are a **provider → host obs** hook, not a second
return path:

- Prefer extending `chat` with an optional `on_chunk` (or a sibling
  `chatStream` that still returns the final `ProviderResult`).
- Host opens the LLM / `agent_round` span, passes a callback that
  coalesces + `appendEvent`s, then closes the span with final attrs.
- Default `llm-simple` adapter uses `streamTextWithFallbacks` for text /
  tool rounds; structured object mode may stay on the non-stream
  generate path.
- The final `ProviderResult` (from `respContent` / equivalent) remains
  the source of authoritative ordered parts and opaque metadata.
  Streaming must not replace or reorder that content.
- Mock adapter must fake chunked delivery for tests.
- Adapters without stream support may ignore `on_chunk` and complete in
  one shot (no progressive events).

See [07-observability.md](07-observability.md) §9 for event channel rules.

### 2.3 Usage and pricing inputs

`TokenUsage` carries total input, output, cache-read, and cache-creation
token counts. Catalog rates may distinguish ordinary input, cache reads,
and cache writes. Pricing rules and span attribute names live in
[07-observability.md](07-observability.md) §3.1.

## 3. Wiring

```text
hwfl run
  → load model-catalog.json
  → select LlmProvider implementation (config / flag)
  → inject into HostEnv
  → llm.* host ops call Provider only
```

Default: `Hwfl.Llm.Simple` wrapping llm-simple.

Escape hatch: `--llm-provider=simple|…` or `project.json` /
env `HWFL_LLM_PROVIDER`.

## 4. Model catalog

Keep a provider-agnostic catalog similar to hwfi:

```json
{
  "modelConfigName": "haiku_4_5",
  "providerName": "claude",
  "modelName": "claude-haiku-4-5-20251001",
  "pricing": {
    "pricePerMillionInput": 1,
    "pricePerMillionOutput": 5,
    "pricePerMillionCacheRead": 0.1,
    "pricePerMillionCacheWrite": 1.25
  },
  "capabilities": {
    "thinking": true,
    "vision": true,
    "promptCaching": true
  }
}
```

Notes:

- `capabilities` is optional for legacy catalogs; missing entries load.
- Requesting an undeclared capability (e.g. thinking) is a classified
  provider error (`InvalidRequestError`).
- Optional `pricePerMillionCacheRead` / `pricePerMillionCacheWrite`
  default to the ordinary input price when omitted.
- Thinking-enabled Claude entries must not set incompatible `temperature`.

The adapter maps `provider` keys to concrete clients. A future adapter
may ignore llm-simple entirely but still honor the catalog.

## 5. Responsibilities split

| Layer         | Owns                                                        |
| ------------- | ----------------------------------------------------------- |
| Host `llm.*`  | typing, effects, spans, schema reflection, agent frame loop |
| `LlmProvider` | HTTP/SDK, auth headers, raw retries if desired              |
| Catalog       | model alias → provider route, rates, capabilities           |

Retries: **either** in the provider **or** in the host — pick one place
in M4 and document. Recommendation: basic retries in provider adapter;
span records attempt count. Retries / fallbacks replay the same engine
history and must not mutate provider metadata.

## 6. Persistence of assistant turns

Canonical snapshot JSON for assistant turns is an ordered `parts` array
(`text` / `thinking` / `tool_call`), including `thinking_opaque` and
tool-call `provider_meta` when present. Legacy

```json
{"tag":"assistant","text":"...","calls":[...]}
```

still decodes (text first when non-empty, then tool calls; no opaque
meta). The next encode writes the canonical `parts` shape. See
`Hwfl.Runtime.Turn` and [06-runtime.md](06-runtime.md).

## 7. Swap acceptance test

Ship a second adapter stub or thin alternate that:

1. Implements `LlmProvider`
2. Is selectable without code changes to workflows
3. Passes a single `llm.chat` integration test with a mock

Full production adapter may live out-of-tree; the **interface stability**
is what v0 guarantees.

## 8. Non-goals

- Supporting every vendor surface area in v0
- Exposing raw SDK types to hwfl authors
- Hot-swapping provider mid-run (forbidden; config at start)
- Author-facing streaming return types in the workflow language
- Requiring every adapter to support progressive deltas
- Author-facing multimodal / image host ops (adapter-ready only)
- Exposing opaque provider payloads as ordinary workflow data
