# 01 — Markdown modules

## 1. Project layout

```text
project.json
model-catalog.json          # required once LLM is used
.env                        # optional; provider secrets (host only)
workflows/
  main.md
tools/                      # optional callable modules
skills/                     # optional agent skills (callable / instruction)
types/                      # optional shared type alias modules
lib/                        # optional libraries
```

- File path relative to project root, without extension, is the module’s
  **qualified name** (qname). Example: `workflows/main.md` → `workflows/main`.
- Renaming a file renames the qname; callers must update. Intentional.
- One top-level declaration per file (workflow entry, library, or type
  module). Multiple primary scripts in one file are rejected in v0.

### 1.1 `project.json` (v0)

```json
{
    "name": "example",
    "version": "0.1.0",
    "entrypoint": "workflows/main",
    "env": [],
    "effects": {
        "default": ["Read", "Net"],
        "deny": []
    },
    "exec": {
        "allow": ["git", "cabal"],
        "env": ["PATH", "HOME"],
        "timeout_ms": 120000,
        "max_output_bytes": 1048576
    },
    "skills": {
        "max_instruction_loads": 5,
        "max_instruction_chars": 12000,
        "max_callable_loads": 20
    }
}
```

- `env`: process env keys exposed to scripts via `env.get` / ambient
  (never provider API keys unless explicitly listed — discouraged).
- `exec`: optional; **absent ⇒ `Exec` effect unavailable** and `exec.*`
  rejected at check time (hwfi policy). Planned: `runtime` / `docker`
  fields for containerized spawn ([05-host-ops.md](05-host-ops.md) §3.1).
- `effects.default`: default allow-set for modules that omit `effects`.
- `skills`: optional budgets for `skill.load` (defaults apply when absent).
- Provider keys (`OPENAI_API_KEY`, etc.) are consumed by the host gateway
  loader and must not appear in script-visible env by default.

## 2. Module file shape

A module is:

1. YAML frontmatter
2. Markdown body: prose headings + at most one primary ` ```hwfl ` block
   (libraries may use multiple named blocks — **[defer]**; v0: one `hwfl`
   block that defines the module body)

### 2.1 Frontmatter

Common fields:

| Field     | Required  | Meaning                                   |
| --------- | --------- | ----------------------------------------- |
| `name`    | yes       | Must equal file qname                     |
| `kind`    | no        | `module` (default), `type-alias`, …       |
| `skill`   | skills/*  | Nested map: `kind`, `summary`, `tags` (see below) |
| `inputs`  | for entry | Record of `name: Type`                    |
| `outputs` | for entry | Record of `name: Type`                    |
| `effects` | no        | Allowed effect set (subset of lattice)    |
| `imports` | no        | List of qnames or `hwfl/...` stdlib paths |
| `examples`| no        | Documented sample run inputs (tooling / UI; not a runtime binding) |

Under `skills/`, missing `skill:` defaults to **callable**. Nested fields:

| Field | Required | Notes |
|-------|----------|-------|
| `skill.kind` | no | `callable` (default) or `instruction` |
| `skill.summary` | recommended | Indexed by `skill.discover` |
| `skill.tags` | no | List of strings; indexed by discover |

**Instruction** skills are prose-only: no ` ```hwfl ` fence (rejected), no
typed `inputs`/`outputs`. **Callable** skills are ordinary typed modules
(same check path as `tools/`). Full behaviour: [skills-plan.md](../skills-plan.md).

`examples` is **authoring / tooling metadata** (control-plane Inputs box,
docs). Omit, `null`, or `[]` means none. Each item:

| Field | Required | Notes |
|-------|----------|-------|
| `name` | no | Non-empty string label for UI / `--example` later |
| `inputs` | yes | YAML mapping → JSON object; keys must match frontmatter `inputs` |

At `hwfl check`, when `examples` is non-empty, each entry’s `inputs` keys
must match frontmatter `inputs` exactly (missing or unknown keys are
errors). Values are not type-checked against `TypeExpr` yet. Keep samples
small and free of secrets. Do **not** put example JSON in a prose `##`
section (those are `@section` prompt bindings).

Example:

```yaml
---
name: workflows/summarise
inputs:
    path: FileRef
outputs:
    summary: String
effects: [Read, Net]
imports:
    - lib/text
examples:
  - name: readme
    inputs:
      path: README.md
---
```

### 2.2 Prose sections

H2/H3 headings define **named sections**. Section body is the raw markdown
between this heading and the next heading of equal or higher level
(excluding fenced `hwfl` code, which is not part of prose bindings).

In kernel code, `@section-slug` (or `section("slug")`) evaluates to that
string. Used for prompts and documentation reuse.

Slug algorithm: lowercase, spaces → `-`, strip non `[a-z0-9-]`, stable.
Documented and tested.

### 2.3 Code fence

Info string `hwfl` (provisional; rename with product). The block contains
kernel declarations and/or an entry expression.

For entry modules (`workflows/*` by convention):

- The block elaborates to a function
  `main : Inputs -> Eff Outputs`
  or an expression of type `Outputs` in a scope with `inputs` bound.
- v0 preferred form: explicit `fun main(inputs): { … } = …` matching
  frontmatter `inputs`/`outputs`.

For libraries: the block exports top-level `fun` / `type` bindings;
frontmatter may list `exports` **[defer]** — v0 exports all top-level
non-`_` names.

## 3. References between modules

Two different mechanisms — do not conflate them:

| Mechanism | Scope | What happens |
|-----------|--------|--------------|
| **Same-project call** (`FrInvoke`) | Imported entry module in this project | Nested evaluation in the **same** run; typed `outputs` |
| **`meta.invoke`** | Nested project / `.md` under a workspace path | Separate child **run** + `run_id` ([05-host-ops.md](05-host-ops.md) §6) |

### 3.1 Imports

- Import brings another module into scope under its qname prefix (aliased
  imports **[defer]**).
- Circular imports are rejected at check time.
- **Libraries** (`lib/*`, non-entry modules): import + call exported
  `fun`s (runtime linking / qname elaboration — separate from entry call).
- **Entry modules** (`workflows/*` and other modules with frontmatter
  `inputs` / `outputs` + `main`): import + call **`main` only** via the
  sugar below. Cross-module helpers belong in `lib/`, not on workflow
  entries.

### 3.2 Same-project entry call (locked)

An imported entry module is callable as:

```hwfl
imports:
  - workflows/inner

-- in body:
let out = workflows/inner({ path = "notes.txt" })
```

Semantics:

- `qname(inputs)` runs the callee’s `main` with the given inputs record.
- Result type is the callee frontmatter `outputs` record.
- Same workspace, same `run_id` — nested frame / span, **not** a new run
  store row. See [06-runtime.md](06-runtime.md) §3.1 (`FrInvoke`).
- Snapshot boundary on enter/return (one nest model with agent tools /
  `par` branches).
- Effects: callee residual effects must be ⊆ caller allow-set (union into
  the caller per [04-effects.md](04-effects.md) §2.6). **No** silent
  `Meta` requirement — `Meta` stays for `meta.invoke` / dynamic
  introspection.
- Check: callee listed in `imports:` (reachable on the import graph),
  has `main`, and I/O match frontmatter.

`tool(f)` whose body performs such a call is allowed; nested human pause
bubbles through the tool machine like any other nested machine.

## 4. Ambient context

Scripts may read a structured ambient value `ctx` (effect `Read` or
`Meta` as appropriate):

| Path                 | Meaning                  |
| -------------------- | ------------------------ |
| `ctx.run.id`         | Current run id           |
| `ctx.run.started_at` | Timestamp                |
| `ctx.workspace`      | Workspace root (logical) |
| `ctx.span`           | Current span id          |
| `ctx.env`            | Whitelisted env map      |

Full prior `ctx.trace` as a giant list is **discouraged** as the primary
API (hwfi pain). Prefer `obs.spans` queries / `meta.read_run` for agents.
v0 may still expose a compact recent-events slice.

## 5. Type-alias modules

`kind: type-alias` modules declare shared types without a script, or
`types/*.md` may contain only `type` declarations in a `hwfl` fence.
Cycles among aliases are rejected.

## 6. Authoring example

````markdown
---
name: workflows/summarise
inputs:
    path: FileRef
outputs:
    summary: String
effects: [Read, Net]
---

## system

You are a concise summariser. One paragraph, no preamble.

## flow

Read a workspace file and summarise it with an LLM.

```hwfl
fun main(inputs): { summary: String } =
  let contents = fs.read(inputs.path)
  let summary = llm.chat(
    system = @system,
    prompt = $"Summarise the following:\n\n{contents.text}",
    model = "gpt-5"
  )
  { summary }
```
````
