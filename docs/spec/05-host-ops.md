# 05 — Host operations

Host ops are runtime primitives. Names below are logical; surface syntax
may be `fs.read(…)` via a prelude module.

Unless noted, each call is one **transition** (snapshot boundary) and
opens/closes a **span**.

## 1. Filesystem (`Read` / `Write`)

| Op | Effects | Signature (sketch) |
|----|---------|-------------------|
| `fs.read` | Read | `(path: FileRef) -> { text: String }` |
| `fs.write` | Write | `(path: FileRef, text: String) -> ()` |
| `fs.list` | Read | `(path: FileRef) -> List<{ name: String, kind: String }>` |
| `fs.read_slice` | Read | `(path, start_line, end_line) -> { text: String }` |
| `fs.find` | Read | `(glob: String) -> List<FileRef>` |
| `fs.grep` | Read | `(pattern, glob?) -> List<Hit>` |
| `fs.edit` | Write | `(path, old, new) -> { ok: Bool }` |
| `fs.move` / `copy` / `remove` / `mkdir` | Write | as expected |

All paths constrained to the **workspace sandbox** (hwfi containment
rules). Symlink escape is a hard failure.

Bytes variants: **[defer]** or ship thin `fs.read_bytes` if required.

## 2. LLM (`Net`)

See also [08-llm-provider.md](08-llm-provider.md).

| Op | Signature (sketch) |
|----|-------------------|
| `llm.chat` | `(system?: String, prompt: String, model: String, …) -> String` |
| `llm.chat_messages` | `(messages: List<Message>, model: String, …) -> String` |
| `llm.object` | `(prompt: String, schema: Schema, model: String) -> T` when `schema = schema(T)` (else `Json`) |
| `llm.agent` | `(system, prompt, tools: List<ToolSpec>, model, …) -> AgentResult` |

Notes:

- `model` resolves through `model-catalog.json`.
- Token usage recorded on the span.
- Failures are catchable (rate limit, provider error) unless marked trap.
- Streaming: **[defer]** for v0, or emit progressive span events if cheap.

### 2.1 Agent tools

A tool is a **typed function** reference plus schema:

```text
tools = [
  tool(fs.read),           -- prelude helper wrapping host op
  tool(lib/search.run)     -- user function
]
```

The agent loop is a machine `Current` state (multi-transition), not a
single opaque host call — same idea as hwfi agent stepping.

## 3. Process (`Exec`)

| Op | Notes |
|----|-------|
| `exec.run` | program basename ∈ allowlist; args; stdin; timeout; capture out/err |

Confirm gate: configurable — either always `confirm` before exec, or
policy flag in `project.json`. **Recommendation:** default confirm on for
anything interactive; CI projects may set `exec.confirm = false`.

## 4. Human (`Human`)

| Op | Notes |
|----|-------|
| `human.confirm` | `{ title, detail }` → `Bool` (or `Approved`/`Denied`) |

Pauses the run (`awaiting_confirm`). In `par`, triggers cooperative
pool freeze ([06-runtime.md](06-runtime.md)).

## 5. Observability (`Read` or pure-ish)

| Op | Notes |
|----|-------|
| `obs.log` | `(level, message, fields: Json) -> ()` — attaches to current span |
| `obs.span` | `(name, fun () -> a) -> a` — nested span region (may be sugar) |

`obs.span` around pure code is allowed; it still creates span events but
need not snapshot every entry if the body is pure — implementer’s choice
as long as host ops inside are correct.

## 6. Meta (`Meta` / `Read`)

| Op | Notes |
|----|-------|
| `meta.invoke` | run another module with inputs (nested frames) **[defer]** |
| `meta.check_module` | check one markdown module; `{ ok, error, name }` (recoverable; M8) |
| `meta.check_project` | whole-project graph check; `{ ok, error }` (workspace-relative project root; M9) |
| `meta.list_runs` | **[defer]** |
| `meta.read_spans` | query spans for a run **[defer]** |
| `meta.read_snapshot` | **careful** — may expose secrets; redact **[defer]** |

`meta.check_module` signature (sketch):

```text
(path: FileRef) -[Meta, Read]-> { ok: Bool, error: String, name: String }
```

## 7. Pure prelude (not host ops)

Shipped in v0 as prelude record projections — **no snapshot boundary**.
Prefer migrating to `lib/*` modules once the import graph exists.

| Module | Op | Signature (sketch) |
|--------|-----|-------------------|
| `list` | `length` | `List<T> -> Int` |
| `list` | `concat` | `List<T> -> List<T> -> List<T>` |
| `text` | `metrics` | `String -> { chars, tokens, lines, entropy, uniqueness }` |
| `text` | `similarity` | `String -> String -> Float` (Jaccard on words) |
| `text` | `contains` | `String -> String -> Bool` |
| `text` | `split_sentences` | `String -> List<String>` |
| `text` | `words` | `String -> List<String>` |
| `text` | `strip_suffix` | `String -> String -> String` |
| `md` | `sections` | `String -> List<{ slug, title, body }>` |
| `json` | `encode` | encodable value → JSON `String` (pure; M8 reports) |

## 8. JSON / data

**Not host ops.** Implement in `lib/json` etc. Exception: if performance
forces a host `json.parse`, document it — still prefer in-language.

## 9. Prelude stability

Breaking host op signatures requires a logged decision and usually a
major/minor bump. Prefer adding new ops over overloading silently.

## 10. Naming

Surface: dotted modules `fs`, `llm`, `exec`, `human`, `obs`, `meta`.  
Internal Haskell: match hwfi’s `builtin/*` only if porting tests — not
required for authors.
