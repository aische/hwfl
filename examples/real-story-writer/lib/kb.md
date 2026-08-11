---
name: lib/kb
effects: [Exec, Write, Read]
imports:
  - types/main
  - lib/util
---

## body

```hwfl
fun ensure_project(pid: String): String =
  let _ =
    try
      let _g = mcp.call(
        server = "kb",
        name = "kb_project_get",
        arguments = { project_id = pid }
      )
      let _r = mcp.call(
        server = "kb",
        name = "kb_project_reset",
        arguments = { project_id = pid, keep_ontology = true }
      )
      "reset"
    catch (_err) =>
      let _c = mcp.call(
        server = "kb",
        name = "kb_project_create",
        arguments = {
          id = pid,
          name = "Real story writer",
          ontology_pack = "fiction.v1"
        }
      )
      "created"
  pid

fun assert_delta(pid: String, mode: String, delta: AssertDelta): AssertResult =
  mcp.call(
    server = "kb",
    name = "kb_assert_delta",
    arguments = { project_id = pid, mode = mode, delta = delta },
    schema = schema(AssertResult)
  )

fun write_snapshot(pid: String, path: String): String =
  let snap = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  let _ = fs.write(path = path, text = json.encode(snap))
  path

fun pack_markdown(pid: String): String =
  let pack = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  json.encode(pack)

fun host_assert_fail(msg: String): AssertResult =
  {
    ok = false,
    batch_id = $"host-err:{msg}",
    mode = "dry_run",
    committed = false,
    findings = lib/util.empty_findings(()),
    applied = {
      entities = lib/util.empty_strings(()),
      aliases = lib/util.empty_strings(()),
      claims = lib/util.empty_strings(()),
      events = lib/util.empty_strings(())
    },
    rejected = {
      claims = lib/util.empty_strings(()),
      events = lib/util.empty_strings(())
    }
  }
```
