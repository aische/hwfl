# `meta` — nested projects and runs

**Effects:** `Meta` + `Read`. Paths are workspace-relative `FileRef`s
(the caller materializes them — often the workspace *is* a tree of child
projects).

Same-project composition is different: `imports: [workflows/inner]` then
`workflows/inner(inputs)` runs callee `main` in the **same** run. No
`Meta`. Prefer that when everything is one `project.json`.

## `meta.check_module`

**Signature:** `(path: FileRef) -> { ok: Bool, error: String, name: String }`

Load + check one markdown module.

## `meta.check_project`

**Signature:** `(path: FileRef) -> { ok: Bool, error: String }`

Load + check a project directory (`project.json`).

## `meta.invoke`

**Signature:** `{ project: FileRef, workspace: FileRef, inputs?: record | Json } -> { ok: Bool, run_id: String, status: String, outcome: Json, error: String }`

Runs a nested project directory or `.md` module via the same driver path
as the CLI. Child `run_id` lives under the **child workspace**
`.hwfl/runs/`. Recoverable: `ok = false` plus `error` rather than always
throwing.

```hwfl
meta.invoke(
  project = "genomes/lean",
  workspace = "genomes/lean",
  inputs = { n = 1 }
)
```

## `meta.list_runs`

**Signature:** `{ workspace: FileRef } -> { ok: Bool, runs: List<{ run_id: String, status: String, entry: String, started_at: String, project_hash: String }>, error: String }`

Lists run metas under that workspace’s `.hwfl/runs`.

## `meta.read_spans`

**Signature:** `{ run_id: String, workspace: FileRef, name_prefix?: String, kind?: String, limit?: Int } -> { ok: Bool, spans: List<Span>, error: String }`

Each span: `{ op, id, parent_id, name, kind, t_start, t_end, status, attrs: Json, snapshot_seq: Int }`.

## `meta.read_snapshot`

**Signature:** `{ run_id: String, workspace: FileRef } -> { ok: Bool, snapshot: Json, error: String }`

Redacted machine snapshot (status, seq, …). Never cleartext secrets.
Missing run → `ok = false`.
