---
name: workflows/main
inputs:
    entry: String
outputs:
    report_path: String
    ok: Bool
    finding_count: Int
effects: [Read, Write, Meta]
---

## overview

Deterministic semantic review (layers 0–2b) written in hwfl. Workspace is the
target project. Layer 0 uses `meta.check_module`; layers 1–2b use in-language
list recursion over `list.length` / `list.concat` plus pure `text` / `md`
helpers. No micro-tool fan-out.

## body

```hwfl
type Finding = {
  severity: String,
  category: String,
  file: String,
  claim: String,
  evidence: String,
  suggestion: String
}

type CheckRow = {
  ok: Bool,
  error: String,
  name: String,
  path: String
}

type Slice = {
  id: String,
  file: String,
  title: String,
  body: String,
  entropy: Float,
  uniqueness: Float
}

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

fun catalog_names(rows: List<CheckRow>, i: Int, n: Int): List<String> =
  if i >= n then []
  else list.concat([rows[i].name], catalog_names(rows, i + 1, n))

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

fun looks_like_qname(tok: String): Bool =
  text.contains(tok, "/") && not(text.contains(tok, "http"))

fun prose_tokens(body: String, names: List<String>, file: String, i: Int, words: List<String>, n: Int): List<Finding> =
  if i >= n then []
  else
    let tok = words[i]
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

fun sum_entropy(xs: List<Slice>, i: Int, n: Int): Float =
  if i >= n then 0.0
  else xs[i].entropy + sum_entropy(xs, i + 1, n)

fun corpus_hints(slices: List<Slice>): List<Finding> =
  let n = list.length(slices)
  corpus_entropy_outliers(slices, mean_entropy(slices, n), 0, n)

fun mean_entropy(slices: List<Slice>, n: Int): Float =
  if n == 0 then 0.0
  else sum_entropy(slices, 0, n) / float_of_int(n)

fun float_of_int(n: Int): Float =
  if n <= 0 then 0.0
  else 1.0 + float_of_int(n - 1)

fun corpus_entropy_outliers(slices: List<Slice>, mean: Float, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let s = slices[i]
    let rest = corpus_entropy_outliers(slices, mean, i + 1, n)
    if s.entropy > mean + 1.0 then
      list.concat(
        [{
          severity = "info",
          category = "corpus",
          file = s.file,
          claim = "Section entropy above local mean",
          evidence = s.id,
          suggestion = "Review for noisy or duplicated guidance"
        }],
        rest
      )
    else rest

fun cluster_pairs(slices: List<Slice>, i: Int, j: Int, n: Int): List<Finding> =
  if i >= n then []
  else if j >= n then cluster_pairs(slices, i + 1, i + 2, n)
  else
    let a = slices[i]
    let b = slices[j]
    let score = text.similarity(a.body, b.body)
    let rest = cluster_pairs(slices, i, j + 1, n)
    if score > 0.85 && not(a.id == b.id) then
      list.concat(
        [{
          severity = "info",
          category = "corpus",
          file = a.file,
          claim = "Similar prose slices (possible redundancy)",
          evidence = $"{a.id} ~ {b.id}",
          suggestion = "Deduplicate or cross-link shared guidance"
        }],
        rest
      )
    else rest

fun is_directive(sentence: String): Bool =
  text.contains(sentence, "must ")
    || text.contains(sentence, "Must ")
    || text.contains(sentence, "should ")
    || text.contains(sentence, "Should ")
    || text.contains(sentence, "always ")

fun speech_in_slice(s: Slice): List<Finding> =
  let sents = text.split_sentences(s.body)
  speech_sents(sents, s, 0, list.length(sents), false)

fun speech_sents(sents: List<String>, s: Slice, i: Int, n: Int, saw: Bool): List<Finding> =
  if i >= n then
    if saw then []
    else if text.contains(s.title, "agent") || text.contains(s.title, "Agent") then
      [{
        severity = "warning",
        category = "speech_act",
        file = s.file,
        claim = "Agent section lacks directive language",
        evidence = s.id,
        suggestion = "Add explicit must/should guidance for the agent"
      }]
    else []
  else
    let sent = sents[i]
    let next = is_directive(sent) || saw
    speech_sents(sents, s, i + 1, n, next)

fun speech_all(slices: List<Slice>, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else list.concat(speech_in_slice(slices[i]), speech_all(slices, i + 1, n))

fun concat3(a: List<Finding>, b: List<Finding>, c: List<Finding>): List<Finding> =
  list.concat(list.concat(a, b), c)

fun concat4(a: List<Finding>, b: List<Finding>, c: List<Finding>, d: List<Finding>): List<Finding> =
  list.concat(concat3(a, b, c), d)

fun take_findings(xs: List<Finding>, k: Int, i: Int, n: Int): List<Finding> =
  if i >= n || k <= 0 then []
  else list.concat([xs[i]], take_findings(xs, k - 1, i + 1, n))

fun all_ok(rows: List<CheckRow>, i: Int, n: Int): Bool =
  if i >= n then true
  else if not(rows[i].ok) then false
  else all_ok(rows, i + 1, n)

fun main(inputs): { report_path: String, ok: Bool, finding_count: Int } =
  let paths = fs.find(glob = "**/*.md")
  let npaths = list.length(paths)
  let rows = check_paths(paths, 0, npaths)
  let names = catalog_names(rows, 0, list.length(rows))
  let structural = structural_from(rows, 0, list.length(rows))
  let entry = entry_findings(inputs.entry, names)
  let prose = prose_all(paths, names, 0, npaths)
  let slices = slices_all(paths, 0, npaths)
  let ns = list.length(slices)
  let corpus = list.concat(
    corpus_hints(slices),
    cluster_pairs(slices, 0, 1, ns)
  )
  let speech = speech_all(slices, 0, ns)
  let findings = concat4(structural, entry, prose, list.concat(corpus, speech))
  let gate = take_findings(findings, 8, 0, list.length(findings))
  let okv = all_ok(rows, 0, list.length(rows))
  let report_obj = {
    schema = "semantic-report/v1",
    mode = "deterministic",
    entry = inputs.entry,
    ok = okv,
    review_gate = gate,
    findings = findings
  }
  let report = json.encode(report_obj)
  let report_path = $".hwfl/runs/{ctx.run.id}/semantic-report.json"
  let _ = fs.write(path = report_path, text = report)
  {
    report_path = report_path,
    ok = okv,
    finding_count = list.length(findings)
  }
```
