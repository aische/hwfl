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
| `fs.find` | Read | `(glob: String) -> List<FileRef>` — skips hidden; root `.gitignore` / `.ignore` (no `.git` required); baseline dependency/build dirs when neither file exists |
| `fs.grep` | Read | `(pattern, glob?) -> List<Hit>` — same ignore rules as `fs.find` |
| `fs.edit` | Write | `(path, old, new) -> { ok: Bool }` |
| `fs.patch` | Write | `(path, hunks: List<{old, new}>) -> { ok, applied, error }` — unique multi-hunk; atomic |
| `fs.mkdir` | Write | `(path: FileRef) -> ()` — create dir and parents |
| `fs.copy` | Write | `{ src, dst, overwrite?, exclude? } -> ()` — file or recursive tree; `exclude` = prefixes under tree root (e.g. `.hwfl/runs`) |
| `fs.move` | Write | `{ src, dst } -> ()` — rename / relocate; fails if `dst` exists |
| `fs.remove` | Write | `(path: FileRef) -> ()` |
| `fs.exists` | Read | `(path: FileRef) -> Bool` |
| `fs.stat` | Read | `(path: FileRef) -> { exists, kind, size }` — `kind` is `file` / `dir` / `""` when missing |

All paths constrained to the **workspace sandbox** (hwfi containment
rules). Symlink escape is a hard failure.

`fs.find` / `fs.grep` ignore policy (v1): hidden path segments are always
skipped; workspace-root `.gitignore` and `.ignore` are applied even when
`.git` is absent; if both are missing or empty, a small built-in baseline
(`node_modules/`, `dist/`, `dist-newstyle/`, `target/`, …) applies. Nested
ignore files and opt-out flags are deferred.

Bytes variants: **[defer]** or ship thin `fs.read_bytes` if required.

## 2. LLM (`Net`)

See also [08-llm-provider.md](08-llm-provider.md).

| Op | Signature (sketch) |
|----|-------------------|
| `llm.chat` | `(system?: String, prompt: String, model: String, …) -> String` |
| `llm.chat_messages` | `(system?: String, messages: List<{ role: String, content: String }>, model: String) -> String` |
| `llm.object` | `(prompt: String, schema: Schema, model: String) -> T` when `schema = schema(T)` (else `Json`) |
| `llm.agent` | `(system, prompt, tools: List<ToolSpec>, model, max_rounds?, history?: List<Turn>, …) -> { text, rounds, history }` |
| `llm.agent_object` | `(system, prompt, tools, schema: Schema, model, max_rounds?, history?: List<Turn>, …) -> { value: T, rounds, history }` when `schema = schema(T)` |

Notes:

- `model` resolves through `model-catalog.json`.
- Token usage recorded on the span.
- Failures are catchable (rate limit, provider error) unless marked trap.
- Streaming (locked): host ops stay **atomic** (one transition, full
  return value). Progressive token / partial text is an **observability
  side channel** only — see [07-observability.md](07-observability.md) §9
  and [08-llm-provider.md](08-llm-provider.md) §2.2. No author-facing
  stream combinator; structured `llm.object` path need not stream.
- `llm.agent_object` injects a synthetic terminating `submit` tool from `schema`
  (hwfi §6.1.3): plain-text finish is fatal; mixed `submit`+other rounds are
  recoverable (no tools run). Surface spelling is `agent_object` (idents have
  no `-`).

**Agent history (`Turn`):** `llm.agent` / `llm.agent_object` accept
optional prior `history` (list of turns: user text, assistant text +
tool calls, tool results — same algebra as host `Turn` / snapshot agent
`agHistory`) and return the updated `history` with the usual result
fields. New `prompt` appends as `TurnUser`. Workflows can own a
multi-turn `human.ask` loop that replays tool-inclusive transcripts
across calls. Do **not** encode tool turns as fake `{ role, content }`
strings; `llm.chat_messages` stays the thin text-only path. Example:
`examples/coding-agent-chat`.

**`max_rounds` budget:** Exhausting `max_rounds` pauses the in-flight
agent (`PauseAwaitingAgent` / status `awaiting_extend`) instead of
failing the run. The operator extends this call’s budget with
`hwfl extend --rounds N` (or `--interactive`); bare `resume` does not
resolve the gate. `CurAgent` / transcript are preserved. Secondary:
structured exhausted return with `history` for outer workflow chaining
(deferred). Until needed, chunk with `history` across agent calls (see
coding-agent-chat).

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

### 3.1 Spawn backend (planned)

Today `exec.run` spawns on the **host** (`Hwfl.Runtime.Exec`). That is
operator-trust isolation (basename allowlist + env allowlist + timeout),
not a security boundary — especially when `bash` / `python3` are allowed.

**Planned:** opt-in spawn backend behind the same `exec.run` API (no new
effect, no ML prelude change). Policy in `project.json`:

| Field | Notes |
|-------|-------|
| `exec.runtime` | `"host"` (default) \| `"docker"` |
| `exec.docker.image` | required when `runtime = docker`; project-chosen |
| `exec.docker.network` | default `"none"` |
| `exec.docker.user` | optional non-root (`uid:gid`) |
| `exec.docker.memory` / `cpus` | optional resource caps |

Docker mode: ephemeral `docker run --rm` per call; bind-mount the
**workspace root** at a fixed workdir so `fs.*` (host) and `exec` (container)
see the same tree. Allowlist + confirm still apply — containers limit host
blast radius, not workspace damage. Missing Docker daemon → clear host
error (no silent fallback to host unless a future explicit policy says so).

Persistent shells (`term.*`) are separate; do not stretch one-shot
`docker run` into a session model. Multi-tenant scheduling stays in
**hwfl-server**; hwfl only exposes the pluggable spawn.

Image choice is per-project (fat “coding” image vs slim toolchain image) —
not a host builtin catalog.

## 4. Human (`Human`)

| Op | Notes |
|----|-------|
| `human.confirm` | `{ title, detail }` → `Bool` (or `Approved`/`Denied`) |
| `human.choice` | `{ title, detail, options: List<String> }` → selected `String` |
| `human.ask` | `{ prompt, detail? }` → free-text `String` |

`human.confirm` pauses the run (`awaiting_confirm`); resolve with
`hwfl approve --yes|--no`. `human.choice` pauses (`awaiting_choice`);
resolve with `hwfl choose --select <option>` (must be one of `options`).
`human.ask` pauses (`awaiting_input`); resolve with
`hwfl reply --text <string>`. Sugar: `confirm { … }` / `choice { … }`.
In `par`, any human gate triggers cooperative pool freeze
([06-runtime.md](06-runtime.md)). Agent tools may wrap `human.choice` /
`human.ask` (nested machine bubbles the pause; choose/reply resumes the
tool result into the agent loop).

## 5. Observability (`Read` or pure-ish)

| Op | Notes |
|----|-------|
| `obs.log` | `(level, message, fields: Json) -> ()` — event (and optional short span) on the current span; **no snapshot boundary** |
| `obs.span` | `(name, fun () -> a) -> a` — nested span region (may be sugar); **region open/close is not a snapshot boundary** |

`obs.log` is observability only (`()`). It must not write a machine
snapshot or become a resume cursor. Crash/resume may drop or duplicate
the log event (best-effort / at-most-once is fine). Do not replay logs
from the event channel as control-flow truth.

`obs.span` around pure code still creates span events but must not
snapshot on region enter/leave; host ops inside the body keep their
normal boundaries.

## 6. Meta (`Meta` / `Read`)

| Op | Notes |
|----|-------|
| `meta.invoke` | nested `driverRun`: `{ project, workspace, inputs? }` → `{ ok, run_id, status, outcome, error }` (workspace-relative paths; snapshot boundary) |
| `meta.check_module` | check one markdown module; `{ ok, error, name }` (recoverable; M8) |
| `meta.check_project` | whole-project graph check; `{ ok, error }` (workspace-relative project root; M9) |
| `meta.list_runs` | list run metas under a workspace; `{ workspace }` → `{ ok, runs, error }` |
| `meta.read_spans` | query spans for a run; `{ run_id, workspace, name_prefix?, kind?, limit? }` → `{ ok, spans, error }` |
| `meta.read_snapshot` | redacted run snapshot Json; `{ run_id, workspace }` → `{ ok, snapshot, error }` |

`meta.invoke` signature (sketch):

```text
{ project: FileRef, workspace: FileRef, inputs?: Record }
  -[Meta, Read]->
  { ok: Bool, run_id: String, status: String, outcome: Json, error: String }
```

- `project` / `workspace` are resolved under the **parent** workspace sandbox.
- Child run state is stored under the **child** workspace (`.hwfl/runs/<run_id>/`).
- **Not** same-project composition: imported entry call `qname(inputs)` →
  nested `FrInvoke` in the **same** run ([01-modules.md](01-modules.md)
  §3.2, [06-runtime.md](06-runtime.md) §3.1). No `Meta` tax for that path.

`meta.list_runs` / `meta.read_spans` / `meta.read_snapshot` (sketch):

```text
{ workspace: FileRef }
  -[Meta, Read]->
  { ok: Bool, runs: List<{ run_id, status, entry, started_at, project_hash }>, error: String }

{ run_id: String, workspace: FileRef, name_prefix?: String, kind?: String, limit?: Int }
  -[Meta, Read]->
  { ok: Bool, spans: List<{ op, id, parent_id, name, kind, t_start, t_end, status, attrs, snapshot_seq }>, error: String }

{ run_id: String, workspace: FileRef }
  -[Meta, Read]->
  { ok: Bool, snapshot: Json, error: String }
```

- `workspace` is parent-sandbox-relative (same containment as `meta.invoke`).
- Missing run → `ok = false`, empty `spans` / null `snapshot`, non-empty `error`.
- Empty / omitted filter fields mean no filter; `limit <= 0` means unlimited.
- `meta.read_snapshot` returns a **redacted** encoding of `snapshot.json`
  (`snapshotToJson` + `redactJson`): format, run_id, seq, status,
  project_hash, last_host, last_result, at, machine, span_stack,
  span_counter. Never a raw FS read of cleartext secrets (spec §07).

## 6.1 Skills (`Meta` / `Read`)

Progressive-disclosure skill catalog for agents. Design + acceptance:
[skills-plan.md](../skills-plan.md). Phases A–C shipped.

| Op | Effects | Signature (sketch) |
|----|---------|-------------------|
| `skill.discover` | Meta, Read | `{ query, kinds, limit } -> { ok, skills, error }` |
| `skill.load` | Meta, Read | `{ id } -> { ok, kind, loaded, content, error }` |

- `discover` returns metadata only (`id`, `kind`, `summary`, `tags`,
  `checked`, `agent_eligible`) — never instruction bodies.
- `load` inside `llm.agent` / `llm.agent_object`: instruction → inject
  context next round; callable → expand active tool set if eligible.
  Outside an agent: instruction returns body in `content`; callable is
  metadata-only (no global tool install).
- Failures are recoverable (`ok = false`), including unknown id, ineligible
  callable, and `project.json` skill budget overflow.
- Authors must list `tool(skill.discover)` / `tool(skill.load)` explicitly —
  no auto-injection into every agent.
- Do not treat `fs.read` of `skills/*.md` as a substitute inside agents.

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
| `text` | `trim` | `String -> String` |
| `text` | `starts_with` | `String -> String -> Bool` |
| `text` | `normalize_token` | strip wrapping punct / backticks |
| `text` | `is_qname` | conservative module qname (`workflows|lib|skills|tools|types|builtin` / …) |
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
