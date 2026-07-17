# 08 — LLM provider adapter

## 1. Requirement

v0 ships with **[llm-simple](https://hackage.haskell.org/package/llm-simple)**
(`^>=0.1.0.1`) as the **default** backend, but workflows and most of the
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

- assistant content (text and/or tool calls)
- usage: input/output tokens (and raw provider payload optionally)
- finish reason

`ProviderError`: catchable classification (auth, rate limit, timeout,
invalid request, other).

### 2.1 Message / tool types

Engine-owned ADTs in `Hwfl.Llm.Types` — **not** re-exported llm-simple
types into Eval. Adapters convert both ways.

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
- Mock adapter must fake chunked delivery for tests.
- Adapters without stream support may ignore `on_chunk` and complete in
  one shot (no progressive events).

See [07-observability.md](07-observability.md) §9 for event channel rules.

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
  "models": {
    "gpt-5": { "provider": "openai", "id": "gpt-5", … }
  }
}
```

The adapter maps `provider` keys to concrete clients. A future adapter
may ignore llm-simple entirely but still honor the catalog.

## 5. Responsibilities split

| Layer         | Owns                                                        |
| ------------- | ----------------------------------------------------------- |
| Host `llm.*`  | typing, effects, spans, schema reflection, agent frame loop |
| `LlmProvider` | HTTP/SDK, auth headers, raw retries if desired              |
| Catalog       | model alias → provider route                                |

Retries: **either** in the provider **or** in the host — pick one place
in M4 and document. Recommendation: basic retries in provider adapter;
span records attempt count.

## 6. Swap acceptance test

Ship a second adapter stub or thin alternate that:

1. Implements `LlmProvider`
2. Is selectable without code changes to workflows
3. Passes a single `llm.chat` integration test with a mock

Full production adapter may live out-of-tree; the **interface stability**
is what v0 guarantees.

## 7. Non-goals

- Supporting every vendor surface area in v0
- Exposing raw SDK types to hwfl authors
- Hot-swapping provider mid-run (forbidden; config at start)
- Author-facing streaming return types in the workflow language
- Requiring every adapter to support progressive deltas
