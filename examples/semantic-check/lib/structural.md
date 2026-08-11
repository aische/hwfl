---
name: lib/structural
effects: [Meta, Read]
imports:
  - types/main
---

## body

```hwfl
fun has_string(xs: List<String>, q: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == q then true
  else has_string(xs, q, i + 1, n)

fun check_paths(paths: List<FileRef>, i: Int, n: Int): List<CheckRow> =
  if i >= n then []
  else
    let p = paths[i]
    let r = meta.check_module(p)
    let path_s = $"{p}"
    let name =
      if r.name == "" then text.strip_suffix(path_s, ".md")
      else r.name
    let row = { ok = r.ok, error = r.error, name = name, path = path_s }
    list.concat([row], check_paths(paths, i + 1, n))

fun structural_from(rows: List<CheckRow>, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let r = rows[i]
    let rest = structural_from(rows, i + 1, n)
    if r.ok then rest
    else
      list.concat(
        [{
          severity = "error",
          category = "structural",
          file = r.path,
          claim = "Module failed check",
          evidence = r.error,
          suggestion = "Fix parse or type errors reported by meta.check_module"
        }],
        rest
      )

fun structural_project(): List<Finding> =
  let r = meta.check_project(".")
  if r.ok then []
  else
    [{
      severity = "error",
      category = "structural",
      file = "project.json",
      claim = "Project failed check",
      evidence = r.error,
      suggestion = "Fix parse or type errors reported by meta.check_project"
    }]

fun entry_findings(entry: String, names: List<String>): List<Finding> =
  if has_string(names, entry, 0, list.length(names)) then []
  else
    [{
      severity = "error",
      category = "entry",
      file = "",
      claim = "Entrypoint not in project catalog",
      evidence = entry,
      suggestion = "Point --input entry= at an existing module qname"
    }]

fun all_ok(rows: List<CheckRow>, i: Int, n: Int): Bool =
  if i >= n then true
  else if not(rows[i].ok) then false
  else all_ok(rows, i + 1, n)

fun empty_rows(_: Unit): List<CheckRow> = []

fun empty_findings(_: Unit): List<Finding> = []
```
