---
name: workflows/verify
inputs:
  program: String
  args: List<String>
outputs:
  exit: Int
  stdout: String
  stderr: String
  ok: Bool
effects: [Exec]
---

## About

Allowlisted check wrapper. Runs `exec.run` and returns a typed result for
the coding session’s serial task loop. Not an agent — no `skill.*` tools.

```hwfl
fun main(inputs: { program: String, args: List<String> }): {
  exit: Int,
  stdout: String,
  stderr: String,
  ok: Bool
} =
  let r = exec.run(
    program = inputs.program,
    args = inputs.args,
    stdin = ""
  )
  {
    exit = r.exit_code,
    stdout = r.stdout,
    stderr = r.stderr,
    ok = r.exit_code == 0 && not(r.timed_out)
  }
```
