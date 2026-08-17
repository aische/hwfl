# `exec` — processes

**Effect:** `Exec`. Durable transition. Requires a non-empty
`project.json` `exec` allowlist; otherwise check fails.

## `exec.run`

**Signature:**

```text
{
  program: String,
  args: List<String>,
  stdin: String
} -> {
  exit_code: Int,
  stdout: String,
  stderr: String,
  timed_out: Bool
}
```

`program` must be a **bare basename** listed in `exec.allow` (no `/` or
`\`). Child environment is **only** the keys in `exec.env`. Pass
`stdin = ""` when unused (the checker requires the field).

```hwfl
let r = exec.run(
  program = "cabal",
  args = ["test"],
  stdin = ""
)
r.exit_code
r.stdout
```

## `project.json`

```json
"exec": {
  "allow": ["echo", "cabal"],
  "env": ["PATH"],
  "timeout_ms": 120000,
  "max_output_bytes": 1048576,
  "confirm": true
}
```

| Field | Default | Meaning |
|-------|---------|---------|
| `allow` | (required for any `exec.run`) | Basename allowlist |
| `env` | `[]` | Parent env keys forwarded to the child |
| `timeout_ms` | runtime default | Wall clock; must be positive |
| `max_output_bytes` | runtime default | Combined output cap; `0` allowed |
| `confirm` | `true` | Pause for `hwfl approve` before spawn |

Set `confirm` to `false` for CI. Spawn is host-local (no Docker runtime
in this version).

Non-zero `exit_code` is a normal result, not a thrown error. Timeouts set
`timed_out = true`.
