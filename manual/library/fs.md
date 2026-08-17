# `fs` — workspace files

**Effects:** `Read` or `Write` as noted. Every call is a durable
transition. Paths are workspace-relative `FileRef`s (string literals
coerce).

## `fs.read`

**Signature:** `(path: FileRef) -> { text: String }`  
**Effects:** Read

```hwfl
let file = fs.read("note.md")
file.text
```

Missing path → catchable host error.

## `fs.read_slice`

**Signature:** `{ path: FileRef, start_line: Int, end_line: Int } -> { text: String }`  
**Effects:** Read

1-based line range (inclusive).

## `fs.write`

**Signature:** `{ path: FileRef, text: String } -> ()`  
**Effects:** Write

Creates parent directories. Overwrites an existing file.

```hwfl
fs.write(path = "out/note.md", text = "hello")
```

## `fs.list`

**Signature:** `(path: FileRef) -> List<{ name: String, kind: String }>`  
**Effects:** Read

`kind` is a directory-entry kind (`file` / `dir` / `symlink`).

## `fs.find`

**Signature:** `{ glob: String } -> List<FileRef>`  
**Effects:** Read

Supported globs: `**/*.ext` and `*.ext`. Extension match is ASCII
case-insensitive. Skips ignored paths (see [Ignore](#ignore)).
Agent-tool eligible (`fs_find`).

```hwfl
fs.find(glob = "**/*.md")
```

## `fs.grep`

**Signature:** `{ pattern: String, glob: String } -> List<{ file: String, line: Int, text: String }>`  
**Effects:** Read

`pattern` is a regex. `glob = ""` (after trim) searches the whole
workspace; otherwise the same globs as `fs.find`. Same ignore rules.

```hwfl
fs.grep(pattern = "TODO", glob = "**/*.md")
fs.grep(pattern = "fn main", glob = "")
```

## `fs.edit`

**Signature:** `{ path: FileRef, old: String, new: String } -> { ok: Bool }`  
**Effects:** Write

Literal replace-**all**. `ok` is true iff at least one hit.

## `fs.patch`

**Signature:** `{ path: FileRef, hunks: List<{ old: String, new: String }> } -> { ok: Bool, applied: Int, error: String }`  
**Effects:** Write

Each `old` must occur **exactly once** after prior hunks in this call.
Applied atomically: failure leaves the file unchanged. Prefer `fs.patch`
for multi-site edits; `fs.edit` only for intentional replace-all.

## `fs.mkdir`

**Signature:** `(path: FileRef) -> ()`  
**Effects:** Write

Creates parents. `fs.write` already creates parents for the file’s
directory — you rarely need `mkdir` first.

## `fs.copy`

**Signature:** `{ src: FileRef, dst: FileRef, overwrite?: Bool, exclude?: List<String> } -> ()`  
**Effects:** Write

File or recursive directory tree. `overwrite` default `false` (fail if
`dst` exists). `exclude` is a list of path prefixes under the tree root
(e.g. `.hwfl/runs`).

## `fs.move`

**Signature:** `{ src: FileRef, dst: FileRef } -> ()`  
**Effects:** Write

Fails if `dst` exists.

## `fs.remove`

**Signature:** `(path: FileRef) -> ()`  
**Effects:** Write

Deletes a file or a directory tree. A symlink is unlinked; the target is
left alone.

## `fs.exists`

**Signature:** `(path: FileRef) -> Bool`  
**Effects:** Read

A symlink counts as present even if its target is missing or outside the
workspace.

## `fs.stat`

**Signature:** `(path: FileRef) -> { exists: Bool, kind: String, size: Int }`  
**Effects:** Read

`kind` is `file` / `dir` / `symlink` / `""` when missing.

## Sandbox

All paths are confined to the workspace root. `..` and absolute paths
fail. A symlink is followed only when it resolves **inside** the
workspace; a link that resolves outside is a hard sandbox failure on
read and write. Workspace-internal symlinks work as aliases.

`fs.exists` / `fs.stat` report the symlink itself (`kind = "symlink"`)
even when the target is missing or outside, so `fs.copy` / `fs.move` will
not silently clobber it.

## Ignore

`fs.find` and `fs.grep` skip:

1. Ignore rules from workspace-root `.gitignore` and `.ignore` (no `.git`
   required). Nested ignore files are not loaded.
2. If both files are missing or empty, a baseline:
   `node_modules/`, `dist/`, `dist-newstyle/`, `target/`, `__pycache__/`,
   `.venv/`, `venv/`, `.stack-work/`, `bower_components/`, `vendor/`,
   `*.pyc`, `*.pyo`, `.DS_Store`.
3. Hidden path segments (`.`-prefixed) unless a negation rule un-ignores
   them (`!.env` can expose `.env`).

## Agent names

`tool(fs.read)` is advertised to the model as `fs_read` (dots →
underscores). Same for the other ops (`fs_write`, `fs_patch`, …).
