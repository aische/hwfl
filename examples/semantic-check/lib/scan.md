---
name: lib/scan
effects: [Read]
imports:
  - types/main
---

## body

```hwfl
fun has_string(xs: List<String>, q: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == q then true
  else has_string(xs, q, i + 1, n)

fun path_catalog_names(paths: List<FileRef>, i: Int, n: Int): List<String> =
  if i >= n then []
  else list.concat([path_to_qname($"{paths[i]}")], path_catalog_names(paths, i + 1, n))

fun path_to_qname(path_s: String): String =
  text.strip_suffix(path_s, ".md")

fun is_module_path(p: String): Bool =
  text.starts_with(p, "workflows/")
    || text.starts_with(p, "skills/")
    || text.starts_with(p, "lib/")
    || text.starts_with(p, "types/")

fun filter_module_paths(paths: List<FileRef>, i: Int, n: Int): List<FileRef> =
  if i >= n then []
  else
    let p = paths[i]
    let rest = filter_module_paths(paths, i + 1, n)
    if is_module_path($"{p}") then list.concat([p], rest)
    else rest

fun slices_file(path: FileRef): List<Slice> =
  let contents = fs.read(path)
  let secs = md.sections(contents.text)
  slices_sections(secs, path, 0, list.length(secs))

fun slices_sections(secs: List<{ slug: String, title: String, body: String }>, file: FileRef, i: Int, n: Int): List<Slice> =
  if i >= n then []
  else
    let s = secs[i]
    let m = text.metrics(s.body)
    let row = {
      id = $"{file}#{s.slug}",
      file = $"{file}",
      title = s.title,
      body = s.body,
      entropy = m.entropy,
      uniqueness = m.uniqueness
    }
    list.concat([row], slices_sections(secs, file, i + 1, n))

fun slices_all(paths: List<FileRef>, i: Int, n: Int): List<Slice> =
  if i >= n then []
  else list.concat(slices_file(paths[i]), slices_all(paths, i + 1, n))

fun has_file_slice(slices: List<Slice>, file: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if slices[i].file == file then true
  else has_file_slice(slices, file, i + 1, n)

fun skill_file_slice(path: FileRef): List<Slice> =
  let contents = fs.read(path)
  let path_s = $"{path}"
  let m = text.metrics(contents.text)
  list.concat([{
    id = $"{path_s}/skill",
    file = path_s,
    title = "skill",
    body = contents.text,
    entropy = m.entropy,
    uniqueness = m.uniqueness
  }], [])

fun ensure_skill_slices(paths: List<FileRef>, slices: List<Slice>, i: Int, n: Int): List<Slice> =
  if i >= n then slices
  else
    let p = paths[i]
    let path_s = $"{p}"
    let next =
      if text.starts_with(path_s, "skills/") && not(has_file_slice(slices, path_s, 0, list.length(slices))) then
        list.concat(slices, skill_file_slice(p))
      else slices
    ensure_skill_slices(paths, next, i + 1, n)
```
