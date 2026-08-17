# Projects and modules

A **project** is a directory with `project.json`. A **module** is a
markdown file under one of the trees below. A lone `.md` file can also be
`check`ed / `run` with an explicit `--workspace`.

## Layout

```text
project.json
model-catalog.json          # required once you call llm.*
.env                        # provider secrets (host only, not script-visible)
workflows/
  main.md                   # typical entrypoint
lib/                        # helpers
types/                      # shared type aliases
tools/                      # optional callable modules
skills/                     # agent skills (callable or instruction)
```

The file path relative to the project root, without `.md`, is the
**qname**. `workflows/main.md` → `workflows/main`. Renaming the file
renames the qname.

Only those five trees are scanned. `README.md` at the project root is not
a module. Hidden directories are skipped.

## `project.json`

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
    "allow": ["cabal"],
    "env": ["PATH"],
    "timeout_ms": 120000,
    "max_output_bytes": 1048576,
    "confirm": true
  },
  "skills": {
    "max_instruction_loads": 5,
    "max_instruction_chars": 12000,
    "max_callable_loads": 20
  }
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `name` | yes | Project name |
| `version` | yes | Free-form string |
| `entrypoint` | yes | Qname of `main` (`workflows/main`) |
| `env` | no | Reserved allowlist of process env keys. **Not** exposed to scripts yet |
| `effects.default` | no | Ceiling when a module omits `effects` |
| `effects.deny` | no | Always subtracted |
| `exec` | no | Absent ⇒ `Exec` unavailable and `exec.run` rejected at check |
| `mcp` | no | Stdio MCP client — [mcp](library/mcp.md) |
| `skills` | no | Load budgets — [skill](library/skill.md) |

`hwfl init [dir]` writes a minimal `project.json` plus
`workflows/main.md` (LLM + confirm).

## Module file

1. YAML frontmatter (required)
2. Markdown body (headings become `@slug` sections)
3. Exactly one ` ```hwfl ` fence, except instruction skills (no fence)

### Frontmatter

| Field | Required | Meaning |
|-------|----------|---------|
| `name` | yes | Must equal the file qname |
| `kind` | no | Parsed, unused by the checker |
| `inputs` | entry | `name: Type` mapping. `{}` for none |
| `outputs` | entry | `name: Type` mapping |
| `effects` | no | Ceiling; else project default |
| `imports` | no | List of qnames |
| `examples` | no | Named sample inputs for `hwfl run --example` |
| `skill` | skills | `kind`, `summary`, `tags` — [skill](library/skill.md) |

```yaml
---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
effects: [Read, Net]
imports:
  - hwfl/list
  - lib/util
  - types/main
examples:
  - name: note
    inputs:
      path: note.md
---
```

Types in `inputs` / `outputs` are strings (`List<String>`, `{ ok: Bool }`).
`examples[].inputs` values are JSON-shaped and checked against those
types at `hwfl check`.

A module with both `inputs` and `outputs` empty (or omitted) is a
**library**: export top-level `fun`s, no `main` required. A module with
I/O is an **entry**: `fun main` required, callable as `qname(inputs)`
from importers.

### Fence

Top-level `type` and `fun` declarations. Entry modules define `fun main`.
A trailing expression instead of `main` is legal in non-entry bodies but
entry I/O always expects `main`.

### Sections

H2 and H3 headings are bound as strings. Slug: lowercase, spaces to `-`,
strip other characters. `@system` reads the section titled “system”.
Duplicate or empty slugs fail to load.

`## schema TypeName` plus `- field: description` bullets document
`schema(TypeName)` fields for the model.

## Imports

```yaml
imports:
  - hwfl/list          # stdlib pack
  - lib/util           # project lib/util.md
  - workflows/inner    # another entry module
  - types/main         # aliases enter scope unqualified
```

Call sites:

```hwfl
hwfl/list.map(xs, f)           -- library export
lib/util.dedupe(rows)
workflows/inner({ x = 1 })     -- callee main, same run
```

Imported type aliases (`Finding`) are unqualified. Duplicate names across
imports are check errors. Project modules cannot use the `hwfl/` prefix.

Same-project `qname(inputs)` unions callee effects into the caller. It
does not require `Meta` and does not create a child run id.

## Project vs workspace

The **project** is code. The **workspace** is data (`fs.*`, `exec.*`,
run store `.hwfl/runs/`). They may be the same directory (hello path,
coding in-place) or different (run `examples/summarise.md` against
`/tmp/ws`).

When `hwfl run`’s target is a **project directory**, the workspace
defaults to that directory. `--workspace` overrides. When the target is a
lone `.md`, pass `--workspace` explicitly.

## Resume and project hash

Snapshots hash **frontmatter + code fence**, not prose. Editing a prompt
section does not brick resume. Changing `fun main` or frontmatter does
(exit `4`). Start a new run after code changes.

## `model-catalog.json`

Array of provider configs. `llm.*` `model` argument is `modelConfigName`.

```json
[
  {
    "modelConfigName": "deepseek4flash",
    "providerName": "deepseek",
    "modelName": "deepseek-v4-flash",
    "pricing": {
      "pricePerMillionInput": 0.14,
      "pricePerMillionOutput": 0.28
    },
    "maxTokens": 10000,
    "temperature": 0.5,
    "requestTimeout": 300000,
    "throttleDelay": 3000,
    "retryCount": 3,
    "jitterBackoff": 1000
  }
]
```
