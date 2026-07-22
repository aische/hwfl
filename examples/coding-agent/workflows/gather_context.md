---
name: workflows/gather_context
inputs:
  query: String
  budget_tokens: Int
outputs:
  context: String
  files: List<FileRef>
  tokens: Int
effects: [Read]
---

## About

Read-only workspace pre-pass: list / find / grep / read under a token
budget. No writes, no agent loop — callable via `FrInvoke` or
`tool(wrap)`.

```hwfl
fun has_dot_hwfl(p: FileRef): Bool =
  text.starts_with($"{p}", ".hwfl/")

fun merge_unique(
  acc: List<FileRef>,
  xs: List<FileRef>,
  i: Int,
  n: Int
): List<FileRef> =
  if i >= n then acc
  else if has_dot_hwfl(xs[i]) then
    merge_unique(acc, xs, i + 1, n)
  else if has_path(acc, xs[i], 0, list.length(acc)) then
    merge_unique(acc, xs, i + 1, n)
  else
    merge_unique(list.concat(acc, [xs[i]]), xs, i + 1, n)

fun has_path(xs: List<FileRef>, p: FileRef, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == p then true
  else has_path(xs, p, i + 1, n)

fun format_entries(
  entries: List<{ name: String, kind: String }>,
  i: Int,
  n: Int
): String =
  if i >= n then ""
  else if i == n - 1 then $"{entries[i].kind}:{entries[i].name}"
  else $"{entries[i].kind}:{entries[i].name}, {format_entries(entries, i + 1, n)}"

fun format_hits(
  hits: List<{ file: String, line: Int, text: String }>,
  i: Int,
  n: Int,
  limit: Int
): String =
  if i >= n then ""
  else if i >= limit then ""
  else
    let line = $"{hits[i].file}:{hits[i].line}: {hits[i].text}"
    if i == n - 1 then line
    else if i == limit - 1 then line
    else $"{line}\n{format_hits(hits, i + 1, n, limit)}"

fun take_paths(xs: List<FileRef>, k: Int, i: Int): List<FileRef> =
  if i >= k then []
  else if i >= list.length(xs) then []
  else list.concat([xs[i]], take_paths(xs, k, i + 1))

fun read_under_budget(
  paths: List<FileRef>,
  i: Int,
  n: Int,
  budget: Int,
  used: Int,
  acc_text: String,
  acc_files: List<FileRef>
): { text: String, files: List<FileRef>, tokens: Int } =
  if i >= n then
    { text = acc_text, files = acc_files, tokens = used }
  else if used >= budget then
    { text = acc_text, files = acc_files, tokens = used }
  else
    let path = paths[i]
    let body = fs.read(path)
    let chunk = $"## {path}\n{body.text}\n"
    let m = text.metrics(chunk)
    if used + m.tokens > budget then
      { text = acc_text, files = acc_files, tokens = used }
    else
      read_under_budget(
        paths,
        i + 1,
        n,
        budget,
        used + m.tokens,
        $"{acc_text}{chunk}",
        list.concat(acc_files, [path])
      )

fun main(inputs: { query: String, budget_tokens: Int }): {
  context: String,
  files: List<FileRef>,
  tokens: Int
} =
  let root = fs.list(".")
  let listing = format_entries(root, 0, list.length(root))
  let py = fs.find(glob = "**/*.py")
  let ts = fs.find(glob = "**/*.ts")
  let tsx = fs.find(glob = "**/*.tsx")
  let hs = fs.find(glob = "**/*.hs")
  let rs = fs.find(glob = "**/*.rs")
  let md = fs.find(glob = "**/*.md")
  let toml = fs.find(glob = "**/*.toml")
  let json = fs.find(glob = "**/*.json")
  let merged0 = merge_unique([], py, 0, list.length(py))
  let merged1 = merge_unique(merged0, ts, 0, list.length(ts))
  let merged2 = merge_unique(merged1, tsx, 0, list.length(tsx))
  let merged3 = merge_unique(merged2, hs, 0, list.length(hs))
  let merged4 = merge_unique(merged3, rs, 0, list.length(rs))
  let merged5 = merge_unique(merged4, md, 0, list.length(md))
  let merged6 = merge_unique(merged5, toml, 0, list.length(toml))
  let candidates = merge_unique(merged6, json, 0, list.length(json))
  let capped = take_paths(candidates, 40, 0)
  let words = text.words(inputs.query)
  let needle =
    if list.length(words) == 0 then ""
    else words[0]
  let hits: List<{ file: String, line: Int, text: String }> =
    if needle == "" then []
    else fs.grep(pattern = needle, glob = "")
  let hit_block = format_hits(hits, 0, list.length(hits), 12)
  let header =
    if listing == "" then
      $"Query: {inputs.query}\nWorkspace: (empty or unlistable)\n"
    else
      $"Query: {inputs.query}\nRoot listing: {listing}\n"
  let grep_block =
    if hit_block == "" then ""
    else $"\nGrep hits for '{needle}':\n{hit_block}\n"
  let preface = $"{header}{grep_block}\n"
  let preface_m = text.metrics(preface)
  let rest_budget =
    if inputs.budget_tokens <= preface_m.tokens then 0
    else inputs.budget_tokens - preface_m.tokens
  let packed = read_under_budget(
    capped,
    0,
    list.length(capped),
    rest_budget,
    0,
    "",
    []
  )
  let context = $"{preface}{packed.text}"
  let total = text.metrics(context)
  {
    context = context,
    files = packed.files,
    tokens = total.tokens
  }
```
