# 09 — CLI

Executable name provisional: **`pml`**.

## 1. Commands (v0)

| Command | Purpose |
|---------|---------|
| `pml check <project>` | Load + type + effects + graph; exit ≠0 on error |
| `pml run <project> [--workspace <dir>] [--input k=v…]` | Check (unless `--no-check`) + execute entrypoint |
| `pml step <workspace> <run-id>` | One transition, then pause |
| `pml resume <workspace> <run-id>` | Continue until end / pause / fail |
| `pml approve <workspace> <run-id> [--yes\|--no]` | Resolve confirm gate |
| `pml show <workspace> <run-id> [flags]` | Spans / status / redacted snapshot |
| `pml version` | |

### Flags (common)

- `--llm-provider <name>`
- `--json` machine-readable diagnostics on check/run errors
- `-v` / `--verbose`

## 2. Inputs

Prefer:

```bash
pml run ./examples/hello --workspace /tmp/ws --input path=README.md
```

Typed coercion from CLI strings per `inputs` types (`FileRef`, `String`,
`Int`, `Bool`, JSON for complex — document).

## 3. Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | check / runtime failure |
| 2 | usage error |
| 3 | paused awaiting confirm (optional convention) |
| 4 | stale project / resume refused |

Exact codes may adjust in M4; stay stable after first release tag.

## 4. Output

- Human logs on stderr
- Primary result JSON on stdout for `run` when `--output json` **[recommend]**
- Spans always on disk under `.pml/runs/…`

## 5. Completions / UX

Nice-to-have **[defer]**: shell completions, `pml init` scaffold.
