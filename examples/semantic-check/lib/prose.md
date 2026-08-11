---
name: lib/prose
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

fun looks_like_qname(tok: String): Bool =
  text.is_qname(tok)

fun prose_tokens(body: String, names: List<String>, file: String, i: Int, words: List<String>, n: Int): List<Finding> =
  if i >= n then []
  else
    let tok = text.normalize_token(words[i])
    let rest = prose_tokens(body, names, file, i + 1, words, n)
    if not(looks_like_qname(tok)) then rest
    else if has_string(names, tok, 0, list.length(names)) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "prose",
          file = file,
          claim = "Unresolved qname mention in prose",
          evidence = tok,
          suggestion = "Add the module or remove the dangling reference"
        }],
        rest
      )

fun prose_file(path: FileRef, names: List<String>): List<Finding> =
  let contents = fs.read(path)
  let secs = md.sections(contents.text)
  prose_sections(secs, names, path, 0, list.length(secs))

fun prose_sections(secs: List<{ slug: String, title: String, body: String }>, names: List<String>, file: FileRef, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let s = secs[i]
    let words = text.words(s.body)
    let here = prose_tokens(s.body, names, $"{file}", 0, words, list.length(words))
    list.concat(here, prose_sections(secs, names, file, i + 1, n))

fun prose_all(paths: List<FileRef>, names: List<String>, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    list.concat(
      prose_file(paths[i], names),
      prose_all(paths, names, i + 1, n)
    )
```
