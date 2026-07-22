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

Read-only workspace pre-pass under a token budget. Skips deep finds when the
workspace is empty (greenfield). When non-empty, scopes `fs.find` globs to the
stack hinted by the query (typescript/react, python, haskell, rust) instead of
scanning every language. No writes, no agent loop.

```hwfl
fun has_dot_hwfl(p: FileRef): Bool =
  text.starts_with($"{p}", ".hwfl/")

fun is_noise_name(name: String): Bool =
  name == ".hwfl"
    || name == ".DS_Store"
    || name == ".vite"
    || name == "node_modules"
    || name == "dist"
    || name == "target"
    || text.starts_with(name, ".")

fun count_signal(
  entries: List<{ name: String, kind: String }>,
  i: Int,
  n: Int
): Int =
  if i >= n then 0
  else if is_noise_name(entries[i].name) then
    count_signal(entries, i + 1, n)
  else
    1 + count_signal(entries, i + 1, n)

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

fun empty_files(): List<FileRef> = []

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

fun q_has(q: String, needle: String): Bool =
  text.contains(q, needle)

fun wants_ts(q: String): Bool =
  q_has(q, "typescript")
    || q_has(q, "TypeScript")
    || q_has(q, "react")
    || q_has(q, "React")
    || q_has(q, "vite")
    || q_has(q, "Vite")
    || q_has(q, "tsx")
    || q_has(q, "TSX")
    || q_has(q, "npm")
    || q_has(q, "node")
    || q_has(q, "Node")
    || q_has(q, "canvas")
    || q_has(q, "javascript")
    || q_has(q, "JavaScript")

fun wants_python(q: String): Bool =
  q_has(q, "python")
    || q_has(q, "Python")
    || q_has(q, "pytest")
    || q_has(q, "pip ")

fun wants_haskell(q: String): Bool =
  q_has(q, "haskell")
    || q_has(q, "Haskell")
    || q_has(q, "cabal")
    || q_has(q, "Cabal")
    || q_has(q, "ghc")

fun wants_rust(q: String): Bool =
  q_has(q, "rust")
    || q_has(q, "Rust")
    || q_has(q, "cargo")
    || q_has(q, "Cargo")

fun find_ts(): List<FileRef> =
  let ts = fs.find(glob = "**/*.ts")
  let tsx = fs.find(glob = "**/*.tsx")
  let json = fs.find(glob = "**/*.json")
  let css = fs.find(glob = "**/*.css")
  let html = fs.find(glob = "**/*.html")
  let m0 = merge_unique([], ts, 0, list.length(ts))
  let m1 = merge_unique(m0, tsx, 0, list.length(tsx))
  let m2 = merge_unique(m1, json, 0, list.length(json))
  let m3 = merge_unique(m2, css, 0, list.length(css))
  merge_unique(m3, html, 0, list.length(html))

fun find_python(): List<FileRef> =
  let py = fs.find(glob = "**/*.py")
  let toml = fs.find(glob = "**/*.toml")
  merge_unique(py, toml, 0, list.length(toml))

fun find_haskell(): List<FileRef> =
  let hs = fs.find(glob = "**/*.hs")
  let cabal = fs.find(glob = "**/*.cabal")
  let toml = fs.find(glob = "**/*.toml")
  let m0 = merge_unique([], hs, 0, list.length(hs))
  let m1 = merge_unique(m0, cabal, 0, list.length(cabal))
  merge_unique(m1, toml, 0, list.length(toml))

fun find_rust(): List<FileRef> =
  let rs = fs.find(glob = "**/*.rs")
  let toml = fs.find(glob = "**/*.toml")
  merge_unique(rs, toml, 0, list.length(toml))

fun find_unknown(): List<FileRef> =
  let json = fs.find(glob = "**/*.json")
  let toml = fs.find(glob = "**/*.toml")
  let md = fs.find(glob = "**/*.md")
  let m0 = merge_unique([], json, 0, list.length(json))
  let m1 = merge_unique(m0, toml, 0, list.length(toml))
  merge_unique(m1, md, 0, list.length(md))

fun candidates_for(q: String): List<FileRef> =
  if wants_ts(q) then find_ts()
  else if wants_python(q) then find_python()
  else if wants_haskell(q) then find_haskell()
  else if wants_rust(q) then find_rust()
  else find_unknown()

fun stack_label(q: String): String =
  if wants_ts(q) then "typescript-react"
  else if wants_python(q) then "python"
  else if wants_haskell(q) then "haskell"
  else if wants_rust(q) then "rust"
  else "unknown"

fun pack_context(
  query: String,
  listing: String,
  stack: String,
  candidates: List<FileRef>,
  budget_tokens: Int
): { context: String, files: List<FileRef>, tokens: Int } =
  let capped = take_paths(candidates, 40, 0)
  let words = text.words(query)
  let needle =
    if list.length(words) == 0 then ""
    else if list.length(words) == 1 then words[0]
    else words[1]
  let hits: List<{ file: String, line: Int, text: String }> =
    if needle == "" then []
    else if list.length(capped) == 0 then []
    else fs.grep(pattern = needle, glob = "")
  let hit_block = format_hits(hits, 0, list.length(hits), 12)
  let header =
    $"Query: {query}\nStack hint: {stack}\nRoot listing: {listing}\n"
  let grep_block =
    if hit_block == "" then ""
    else $"\nGrep hits for '{needle}':\n{hit_block}\n"
  let preface = $"{header}{grep_block}\n"
  let preface_m = text.metrics(preface)
  let rest_budget =
    if budget_tokens <= preface_m.tokens then 0
    else budget_tokens - preface_m.tokens
  let packed = read_under_budget(
    capped,
    0,
    list.length(capped),
    rest_budget,
    0,
    "",
    empty_files()
  )
  let context = $"{preface}{packed.text}"
  let total = text.metrics(context)
  {
    context = context,
    files = packed.files,
    tokens = total.tokens
  }

fun main(inputs: { query: String, budget_tokens: Int }): {
  context: String,
  files: List<FileRef>,
  tokens: Int
} =
  let root = fs.list(".")
  let listing = format_entries(root, 0, list.length(root))
  let signals = count_signal(root, 0, list.length(root))
  if signals == 0 then
    let ctx =
      $"Query: {inputs.query}\nWorkspace: empty (greenfield). Skip file survey.\n"
    let m = text.metrics(ctx)
    { context = ctx, files = empty_files(), tokens = m.tokens }
  else
    let stack = stack_label(inputs.query)
    let candidates = candidates_for(inputs.query)
    pack_context(
      inputs.query,
      listing,
      stack,
      candidates,
      inputs.budget_tokens
    )
```
