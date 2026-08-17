# Library

Three layers. Do not conflate them.

| Layer | Location | How found | Examples |
|-------|----------|-----------|----------|
| **Prelude / host** | Interpreter | Always in scope | `list.length`, `fs.read`, `text.trim`, `+` |
| **Stdlib pack** | Markdown next to the install (`HWFL_STDLIB` or default) | `imports: [hwfl/list]` | `hwfl/list`, `hwfl/option` |
| **Project `lib/`** | `<project>/lib/*.md` | `imports: [lib/foo]` | `lib/story_claims` |

Host ops are privileged: filesystem sandbox, LLM provider, process spawn,
MCP, human gates, nested runs. Everything else belongs in stdlib or
`lib/`.

## Pages

| Page | Contents |
|------|----------|
| [Prelude](prelude.md) | `list.*`, `text.*`, `md.*`, `json.encode`, `tool`, `schema`, `ctx`, operators |
| [fs](fs.md) | Workspace files |
| [llm](llm.md) | Chat, structured object, agents |
| [Agent context](llm-context.md) | `context_window`, `consolidate`, pins |
| [exec](exec.md) | `exec.run` |
| [human](human.md) | Confirm, choice, ask |
| [obs](obs.md) | Log and spans |
| [meta](meta.md) | Nested check / invoke / inspect |
| [skill](skill.md) | Discover and load |
| [mcp](mcp.md) | Stdio MCP client |
| [Stdlib](stdlib.md) | `hwfl/list`, `hwfl/string`, `hwfl/option`, `hwfl/result` |

## Call style

Named arguments for host ops:

```hwfl
fs.write(path = "note.md", text = "hi")
llm.chat(system = @system, prompt = "Hi", model = "deepseek4flash")
```

A single record value is the same as named fields. Positional works when
the domain is one value (`fs.read("note.md")`, `list.length(xs)`).

Optional fields (`detail?`, `history?`) are omitted, not passed as empty
unless the docs say empty is meaningful (`fs.grep` `glob = ""`).

## Durability

Each host call is one **transition** (snapshot + span) unless the page
says otherwise. `obs.*` is not a snapshot boundary. Pure prelude and
stdlib are not.

Failed host/provider/sandbox ops are catchable with `try` / `catch`.
See [syntax](../language.md).
