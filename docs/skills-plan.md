# Skills — implementation plan

**Status:** implemented (phases A–C). Normative behaviour should move into
`spec/01-modules.md`, `spec/05-host-ops.md`, and `spec/06-runtime.md`.

**Reference:** hwfi `docs/skills-design.md`, spec §6.6–§6.7, and
`Hwfi.SkillCatalog` / `Hwfi.Runtime.Skills`. Reuse behaviour and tests;
do **not** reintroduce the step DSL.

## 1. Goal

Cursor-style **progressive disclosure** for agent workflows:

1. Authors (or prior runs) materialize reusable skills under `skills/`.
2. Agents **discover** matching skills by metadata only.
3. Agents **load** only what they need mid-loop.
4. Load has kind-specific effects: inject prose **or** expand the
   active tool set — not merely `fs.read` of a markdown file.

Skills are **project-scoped**, checked with the rest of the project, and
durable across resume. No package registry (see [idea.md](idea.md)
non-goals).

## 2. Design principles

1. **Two kinds, one catalog.** `callable` and `instruction` share
   discover/load; differ only in load effect and check rules.
2. **Declarations, not a parallel runtime.** Callable skills are ordinary
   typed modules (same parser, checker, `tool(f)` dispatch as `tools/`).
3. **Progressive disclosure.** Discover returns metadata; load pulls body
   or advertises a tool. Large libraries stay out of context until needed.
4. **Explicit meta-tools.** Authors include `skill.discover` /
   `skill.load` in `llm.agent` / `llm.agent_object` `tools` lists. No
   implicit injection.
5. **Recoverable failures.** Unknown id, failed check, ineligible
   callable, budget overflow → `{ ok = false, … }`, not run abort.
6. **Resume-correct.** Agent checkpoints record loaded callables and
   instructions; advertised-tool fingerprints include the active set.

## 3. Skill kinds

| Kind | Body | Check | Load effect (inside agent) |
|------|------|-------|----------------------------|
| `callable` (default) | Typed module / tool entry | Full `hwfl check` + agent-eligibility | Join **active tool set** next model round |
| `instruction` | Markdown prose only (no executable kernel required) | Frontmatter + non-empty body; no typed I/O required | Append body to **instruction context** before next model round |

### Callable example

```yaml
---
name: skills/fix-shell
skill:
  kind: callable
  summary: "Fix sh syntax errors using sh -n"
  tags: [shell, syntax]
inputs: { path: FileRef }
outputs: { ok: Bool }
effects: [Read, Write, Exec]
---

# Fix shell

Prose for humans / extraction context.

```hwfl
fun main(inputs) = …
```
```

### Instruction example

```yaml
---
name: skills/shell-repair-guide
skill:
  kind: instruction
  summary: "sh -n repair workflow for shell scripts"
  tags: [shell]
---

# Shell repair

Always run `sh -n` before and after editing…
```

## 4. Project layout & catalog

Extend the author layout:

```text
skills/
  <name>.md          # skill modules (optional tree)
```

- Qname = path without extension (`skills/fix-shell.md` →
  `skills/fix-shell`), same rule as other modules.
- At `hwfl check`, build an immutable **SkillCatalog** from every module
  under `skills/` (and any other path declared skill-bearing if we later
  allow that — v1: `skills/` only).
- Catalog entry fields (discover surface):

  | Field | Meaning |
  |-------|---------|
  | `id` | Qname |
  | `kind` | `"callable"` \| `"instruction"` |
  | `summary` | Short string (required for discover usefulness; empty allowed but discouraged) |
  | `tags` | List of strings |
  | `checked` | Passed project check |
  | `agent_eligible` | Callable may be advertised as an agent tool (same eligibility rules as `tool(f)` today) |

Scripted workflows may also call discover/load outside an agent (see §6).

### 4.1 Frontmatter

| Field | Required | Notes |
|-------|----------|-------|
| `name` | yes | Must equal file qname |
| `skill.kind` | no | Default `callable` |
| `skill.summary` | recommended | Indexed by discover |
| `skill.tags` | no | Indexed by discover |
| `inputs` / `outputs` / `effects` | callable only | Same as ordinary modules |

Instruction skills **must not** declare an executable `main` / typed
entrypoint that would make them ordinary workflows; if a fence exists, it
is rejected or ignored only by explicit logged decision — **prefer reject**
to avoid two meanings.

### 4.2 `project.json` policy (sketch)

```json
{
  "skills": {
    "max_instruction_loads": 5,
    "max_instruction_chars": 12000,
    "max_callable_loads": 20
  }
}
```

Defaults apply when the section is absent. Exceeding caps is a recoverable
load failure.

## 5. Host ops

Surface under `skill.*` (hwfl dotted modules; not hwfi `builtin/*` paths).

| Op | Effects | Signature (sketch) |
|----|---------|-------------------|
| `skill.discover` | `Meta`, `Read` | `(query: String, kinds: List<String>, limit: Int) -> { ok: Bool, skills: List<SkillEntry>, error: String }` |
| `skill.load` | `Meta`, `Read` | `(id: String) -> { ok: Bool, kind: String, loaded: Bool, content: String, error: String }` |

### 5.1 `skill.discover`

- Case-insensitive substring match on `id`, `summary`, and `tags`.
- `kinds`: filter to `"callable"` / `"instruction"`; empty = all.
- `limit` ≥ 1 (default 20).
- Returns metadata only — **no bodies**.
- Snapshot-boundary host op; cacheable in the sense of “no agent mutation”
  (same transition rules as other read-ish meta ops).

### 5.2 `skill.load`

**Inside** `llm.agent` / `llm.agent_object`:

- **instruction** — append body (markdown after frontmatter) to the agent’s
  instruction context as a synthetic system segment
  (`## Loaded skill: <id>`). Set `content` to that body; `loaded = true`
  if newly injected, `false` if already loaded (idempotent).
- **callable** — if `checked` and `agent_eligible`, add to the agent’s
  **active tool set** for subsequent rounds. Provider receives updated
  tool definitions on the next model call. `content` may be empty or a
  short confirmation string; do not dump the whole module source into
  the model by default.
- Unknown / ineligible / budget → `ok = false` with `error`.

**Outside** an agent:

- **instruction** — return body in `content` for the caller to concatenate
  into `system` / prompts manually.
- **callable** — do **not** silently become a global tool; return
  `ok = true` with metadata / empty content, or a structured ref the
  caller can pass into a later `tools` list expression. Prefer a clear
  typed result once first-class tool refs are stable; until then document
  the interim shape in the implementation PR.

`skill.load` mutates agent state when inside a loop → **non-cacheable**
relative to pure catalog reads; always a real transition.

### 5.3 Agent toolbox pattern

```hwfl
llm.agent(
  system = @self#agent,
  prompt = "Fix ${inputs.target}",
  tools = [
    tool(skill.discover),
    tool(skill.load),
    tool(fs.read),
    tool(fs.edit),
    tool(exec.run)
  ],
  model = "smart",
  max_rounds = 16
)
```

Typical model sequence:

1. `skill.discover(query = "shell syntax", kinds = [], limit = 5)`
2. `skill.load(id = "skills/shell-repair-guide")` — instruction
3. `skill.load(id = "skills/fix-shell")` — callable next round
4. Use newly advertised tools to finish

## 6. Runtime & resume

Extend agent `Current` / snapshot (names illustrative):

| Field | Role |
|-------|------|
| `active_tool_ids` | Ordered callable skill qnames loaded so far (+ baseline `tools`) |
| `loaded_instruction_ids` | Instruction skills already merged into context |
| `instruction_context` | Accumulated injected prose (or reconstruct from ids + catalog) |

Rules:

- Loading the same `id` twice is idempotent (`loaded = false`).
- Model-call fingerprint / span attrs must include the active tool set at
  **round start** so resume does not replay a round with a different
  advertised toolbox.
- Instruction loads affect the message list directly; resume must restore
  messages **or** rebuild from `loaded_instruction_ids` + catalog (pick one
  strategy and test it; prefer rebuild-from-ids if messages are large).

Cooperative with existing agent eligibility: callables that transitively
reach forbidden ops (e.g. full introspect dumping secrets) stay
ineligible — same policy as today’s `tool(f)` checks.

## 7. Observability

Emit span / audit events (names illustrative):

- `skill.discover` — query, kinds, limit, hit count
- `skill.load` — id, kind, loaded?, ok/error

`hwfl show` should surface load/discover under the enclosing agent span.

## 8. Extraction (phase 2, optional)

Not required for consume-path skills, but part of the full loop:

1. Read a prior run slice (`meta.read_spans` / future trace-slice).
2. LLM-draft a skill markdown file (Mode A).
3. `fs.write` under `skills/`.
4. Author runs `hwfl check`; next run can discover/load.

Do **not** ship a host `skill.extract` that hides an LLM call unless it
stays a thin convenience over Mode A. Prefer in-language workflows.

## 9. Implementation phases

### Phase A — Catalog + check (no agent mutation yet)

1. Parse `skill:` frontmatter; instruction vs callable declarations.
2. Include `skills/` in project discovery / import graph as needed.
3. `buildSkillCatalog` at check time; surface errors for bad instruction
   files and failed callables.
4. Unit tests: catalog entries, kind parsing, eligibility flags.

### Phase B — Host ops (scripted use)

1. Prelude / host registration: `skill.discover`, `skill.load`.
2. Outside-agent semantics + recoverable errors.
3. `project.json` skill budgets.
4. Example workflow that discovers and concatenates an instruction into
   `llm.chat` system prompt.

### Phase C — Agent mid-loop load (the correctness bar)

1. Wire load into `CurAgent` / tool dispatch.
2. Expand advertised tools between rounds for callables.
3. Inject instruction context for instructions.
4. Persist `active_tool_ids` / `loaded_instruction_ids` in snapshots.
5. Resume tests: crash after load, resume, next round sees tools/context.
6. Idempotent double-load tests; budget overflow tests.
7. Example: agent toolbox with discover + load + one domain tool.

### Phase D — Extraction dogfood (optional)

1. Small `examples/skills/` writer workflow.
2. Decision-log note comparing to hwfi Mode A.

## 10. Acceptance sketch (when implementing)

- [x] `skills/*.md` appear in catalog after `hwfl check`
- [x] `skill.discover` filters by query / kinds / limit; metadata only
- [x] `skill.load` instruction inside agent injects context next round
- [x] `skill.load` callable inside agent advertises tool next round
- [x] Double load is idempotent
- [x] Budget overflow is recoverable (`ok = false`)
- [x] Snapshot resume restores active tools + loaded instructions
- [x] Ineligible callable cannot be loaded as an agent tool
- [x] No implicit injection of discover/load into every agent
- [ ] Semantic-check (or a smaller example) can use skills without
      hardcoding every callable in the initial `tools` list
      → covered by `examples/skills` + SkillSpec; semantic-check dogfood deferred

## 11. What not to build

- Cross-workspace or registry-backed skills
- Embedding / vector search in v1 (substring + tags only)
- A separate skill VM or step-DSL dialect for callables
- Magic auto-load of all skills into every agent
- Treating `fs.read("skills/…")` as a substitute for `skill.load` inside
  agents (bypasses budgets, eligibility, and tool advertising)

## 12. hwfi → hwfl map

| hwfi | hwfl |
|------|------|
| `builtin/discover-skills` | `skill.discover` |
| `builtin/load-skill` | `skill.load` |
| `skills/*.md` + `skill:` frontmatter | same shape |
| `SkillCatalog` at check | `Hwfl.SkillCatalog` (new) |
| Agent `active-tool-ids` / instruction ids | agent snapshot fields (§6) |
| Mode A extraction | phase D; prefer hwfl modules |

## 13. Open questions (resolved in implementation)

1. **Rebuild vs store instruction text** — **rebuild-from-ids.** Snapshots
   persist `loaded_instruction_ids` (+ char budget); model rounds rebuild
   injection text from the catalog. Base `agSystem` is never mutated.
2. **Callable load outside agent** — interim: `{ ok, kind=callable,
   loaded=false, content="", error="" }` (no global tool install). Dynamic
   `ToolSpec` values for later `tools` assembly deferred until first-class
   tool refs are stable.
3. **CLI** `hwfl skill list` — **skipped**; `skill.discover` suffices.
4. Instruction skills with example fences — **rejected** (`hwfl` fence
   forbidden on instruction skills).
