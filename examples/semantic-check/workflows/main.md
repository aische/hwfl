---
name: workflows/main
inputs:
    entry: String
    mode: String
    model: String
outputs:
    report_path: String
    ok: Bool
    finding_count: Int
effects: [Read, Write, Meta, Net]
---

## overview

Semantic review written in hwfl (layers 0–2b deterministic; optional same-run
layer 3 pragmatic via `llm.object`). Workspace is the target project. Scans
module trees only (`workflows/`, `skills/`, `lib/`, `types/`) — not README or
other docs. Always emits body-bearing `review_gate` items. Set
`mode=pragmatic` (and a catalog `model`) to run gated LLM review in the same
run; `mode=deterministic` skips LLM calls. No micro-tool fan-out.

## reviewer

You review workflow prose for pragmatic coherence. You receive a slice body and,
for pair reviews, a peer slice body. Selection metadata explains why the slice
was flagged; it is not part of the prose under review.

Rules:
- Judge only text in **Slice under review** and **Peer slice** sections.
- Do not comment on entropy, compression, outliers, or review tooling unless
  those words appear in the slice bodies.
- Felicity violations must cite phrases from the slice bodies.
- Be conservative: only flag issues with evidence in the bodies.

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

type GateItem = {
  slice_id: String,
  file: String,
  body: String,
  gate_source: String,
  review_task: String,
  peer_file: String,
  peer_body: String,
  context: String,
  priority: Int
}

type PragmaticOut = {
  illocutionary_force: String,
  felicity_violations: List<String>,
  contradictions: List<{ other_location: String, evidence: String }>,
  clarity_score: Float
}

type Contradiction = { other_location: String, evidence: String }

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
    || text.contains(sentence, "Always ")
    || text.contains(sentence, "never ")
    || text.contains(sentence, "Never ")
    || text.contains(sentence, "do not ")
    || text.contains(sentence, "Do not ")
    || text.contains(sentence, "don't ")
    || text.contains(sentence, "Don't ")

fun speech_in_slice(s: Slice): List<Finding> =
  let sents = text.split_sentences(s.body)
  speech_sents(sents, s, 0, list.length(sents), false)

fun is_agent_section(title: String): Bool =
  text.contains(title, "agent")
    || text.contains(title, "Agent")
    || text.contains(title, "system")
    || text.contains(title, "System")
    || text.contains(title, "reviewer")
    || text.contains(title, "Reviewer")

fun speech_sents(sents: List<String>, s: Slice, i: Int, n: Int, saw: Bool): List<Finding> =
  if i >= n then
    if saw then []
    else if is_agent_section(s.title) then
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

fun all_ok(rows: List<CheckRow>, i: Int, n: Int): Bool =
  if i >= n then true
  else if not(rows[i].ok) then false
  else all_ok(rows, i + 1, n)

fun find_slice(slices: List<Slice>, id: String, i: Int, n: Int): List<Slice> =
  if i >= n then []
  else if slices[i].id == id then [slices[i]]
  else find_slice(slices, id, i + 1, n)

fun find_slice_for_prose(slices: List<Slice>, file: String, evidence: String, i: Int, n: Int): List<Slice> =
  if i >= n then []
  else
    let s = slices[i]
    if s.file == file && text.contains(s.body, evidence) then [s]
    else find_slice_for_prose(slices, file, evidence, i + 1, n)

fun gate_has_id(xs: List<GateItem>, id: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i].slice_id == id then true
  else gate_has_id(xs, id, i + 1, n)

fun gate_append_unique(acc: List<GateItem>, item: GateItem): List<GateItem> =
  if gate_has_id(acc, item.slice_id, 0, list.length(acc)) then acc
  else list.concat(acc, [item])

fun gate_merge(acc: List<GateItem>, xs: List<GateItem>, i: Int, n: Int): List<GateItem> =
  if i >= n then acc
  else gate_merge(gate_append_unique(acc, xs[i]), xs, i + 1, n)

fun take_gates(xs: List<GateItem>, k: Int, i: Int, n: Int): List<GateItem> =
  if i >= n || k <= 0 then []
  else list.concat([xs[i]], take_gates(xs, k - 1, i + 1, n))

fun similarity_gates(slices: List<Slice>, i: Int, j: Int, n: Int): List<GateItem> =
  if i >= n then []
  else if j >= n then similarity_gates(slices, i + 1, i + 2, n)
  else
    let a = slices[i]
    let b = slices[j]
    let score = text.similarity(a.body, b.body)
    let rest = similarity_gates(slices, i, j + 1, n)
    if score > 0.85 && not(a.id == b.id) then
      let item =
        if a.entropy == b.entropy then
          {
            slice_id = a.id,
            file = a.file,
            body = a.body,
            gate_source = "redundancy",
            review_task = "check_redundancy",
            peer_file = b.file,
            peer_body = b.body,
            context = $"{a.id} ~ {b.id}",
            priority = 30
          }
        else
          {
            slice_id = a.id,
            file = a.file,
            body = a.body,
            gate_source = "cluster_divergence",
            review_task = "check_contradiction",
            peer_file = b.file,
            peer_body = b.body,
            context = $"{a.id} ~ {b.id}; entropy diverge",
            priority = 25
          }
      list.concat([item], rest)
    else rest

fun speech_gates(findings: List<Finding>, slices: List<Slice>, i: Int, n: Int): List<GateItem> =
  if i >= n then []
  else
    let f = findings[i]
    let rest = speech_gates(findings, slices, i + 1, n)
    if not(f.category == "speech_act") then rest
    else
      let hits = find_slice(slices, f.evidence, 0, list.length(slices))
      if list.length(hits) == 0 then rest
      else
        let s = hits[0]
        list.concat(
          [{
            slice_id = s.id,
            file = s.file,
            body = s.body,
            gate_source = "speech_act_mismatch",
            review_task = "check_coverage_gap",
            peer_file = "",
            peer_body = "",
            context = f.claim,
            priority = 20
          }],
          rest
        )

fun prose_gates(findings: List<Finding>, slices: List<Slice>, i: Int, n: Int): List<GateItem> =
  if i >= n then []
  else
    let f = findings[i]
    let rest = prose_gates(findings, slices, i + 1, n)
    if not(f.category == "prose") then rest
    else if not(f.severity == "warning") then rest
    else
      let hits = find_slice_for_prose(slices, f.file, f.evidence, 0, list.length(slices))
      if list.length(hits) == 0 then rest
      else
        let s = hits[0]
        list.concat(
          [{
            slice_id = s.id,
            file = s.file,
            body = s.body,
            gate_source = "dead_reference",
            review_task = "check_dead_reference",
            peer_file = "",
            peer_body = "",
            context = $"unresolved_qname={f.evidence}",
            priority = 10
          }],
          rest
        )

fun build_gate(slices: List<Slice>, prose: List<Finding>, speech: List<Finding>): List<GateItem> =
  let sim = similarity_gates(slices, 0, 1, list.length(slices))
  let sp = speech_gates(speech, slices, 0, list.length(speech))
  let pr = prose_gates(prose, slices, 0, list.length(prose))
  let merged = gate_merge(gate_merge(gate_merge([], sim, 0, list.length(sim)), sp, 0, list.length(sp)), pr, 0, list.length(pr))
  take_gates(merged, 8, 0, list.length(merged))

fun bleed_felicity(s: String): Bool =
  text.contains(s, "entropy")
    || text.contains(s, "outlier")
    || text.contains(s, "compression")
    || text.contains(s, "review_gate")

fun felicity_findings(xs: List<String>, file: String, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let s = xs[i]
    let rest = felicity_findings(xs, file, i + 1, n)
    if bleed_felicity(s) then rest
    else if s == "" then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "ambiguity",
          file = file,
          claim = "Felicity violation in gated prose",
          evidence = s,
          suggestion = "Clarify preconditions or directive scope"
        }],
        rest
      )

fun contradiction_findings(xs: List<Contradiction>, file: String, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let c = xs[i]
    let rest = contradiction_findings(xs, file, i + 1, n)
    list.concat(
      [{
        severity = "warning",
        category = "contradiction",
        file = file,
        claim = $"Possible contradiction vs {c.other_location}",
        evidence = c.evidence,
        suggestion = "Reconcile conflicting guidance"
      }],
      rest
    )

fun pragmatic_to_findings(out: PragmaticOut, item: GateItem): List<Finding> =
  list.concat(
    felicity_findings(out.felicity_violations, item.file, 0, list.length(out.felicity_violations)),
    contradiction_findings(out.contradictions, item.file, 0, list.length(out.contradictions))
  )

fun peer_block(item: GateItem): String =
  if item.peer_body == "" then ""
  else $"\n\n## Peer slice\nLocation: {item.peer_file}\n\n{item.peer_body}"

fun review_one(item: GateItem, model: String): List<Finding> =
  let prompt =
    $"{@reviewer}\n\n## Slice under review\nLocation: {item.file}\n\n{item.body}{peer_block(item)}\n\n## Review task\n{item.review_task}\n\n## Context\n{item.context}"
  let out = llm.object(
    prompt = prompt,
    schema = schema(PragmaticOut),
    model = model
  )
  pragmatic_to_findings(out, item)

fun review_all(gate: List<GateItem>, model: String, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else list.concat(review_one(gate[i], model), review_all(gate, model, i + 1, n))

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

fun main(inputs): { report_path: String, ok: Bool, finding_count: Int } =
  let all_md = fs.find(glob = "**/*.md")
  let paths = filter_module_paths(all_md, 0, list.length(all_md))
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
  let gate = build_gate(slices, prose, speech)
  let pragmatic =
    if inputs.mode == "pragmatic" then
      review_all(gate, inputs.model, 0, list.length(gate))
    else
      []
  let okv = all_ok(rows, 0, list.length(rows))
  let report_obj = {
    schema = "semantic-report/v1",
    mode = inputs.mode,
    entry = inputs.entry,
    ok = okv,
    review_gate = gate,
    findings = findings,
    pragmatic_findings = pragmatic
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
