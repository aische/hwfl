# `skill` — catalog

**Effects:** `Meta` + `Read`. Skills live under project `skills/*.md`.
Discover returns **metadata only**. Load injects instruction text or
runs a callable module.

Neither op is auto-injected into agents. List them in `tools = […]`.

## `skill.discover`

**Signature:** `{ query: String, kinds: List<String>, limit: Int } -> { ok: Bool, skills: List<Row>, error: String }`

Each row: `{ id: String, kind: String, summary: String, tags: List<String>, checked: Bool, agent_eligible: Bool }`.

`kinds` filters `"callable"` / `"instruction"`. Empty query matches all.
`limit` caps the result list.

```hwfl
skill.discover(query = "python", kinds = ["instruction"], limit = 5)
```

## `skill.load`

**Signature:** `{ id: String } -> { ok: Bool, kind: String, loaded: Bool, content: String, error: String }`

`id` is the skill qname (`skills/python-pytest`). Inside an agent,
instruction load injects the prose into context; callable load exposes
the skill as a tool subject to budgets. Outside an agent, instruction
returns `content`.

## Skill files

**Instruction** (prose only — no `hwfl` fence, no `inputs`/`outputs`):

```markdown
---
name: skills/shell-repair-guide
skill:
  kind: instruction
  summary: "sh -n repair workflow for shell scripts"
  tags: [shell, syntax]
---

# Shell repair

Always run `sh -n` before and after editing a shell script.
```

**Callable** (ordinary typed module):

````markdown
---
name: skills/echo-note
skill:
  kind: callable
  summary: "Echo a short note"
  tags: [demo]
inputs:
  msg: String
outputs:
  text: String
effects: []
---

```hwfl
fun main(inputs): { text: String } = { text = inputs.msg }
```
````

Missing `skill:` under `skills/` defaults to callable.

## Budgets (`project.json`)

```json
"skills": {
  "max_instruction_loads": 5,
  "max_instruction_chars": 12000,
  "max_callable_loads": 20
}
```

Defaults when omitted: 5 / 12000 / 20. Skills with `Secret<_>` inputs
are not agent-eligible.
