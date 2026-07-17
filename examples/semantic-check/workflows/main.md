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
other docs.

Deterministic: structural / prose qnames / entropy info / **within-slice
quoted sentence redundancy** (capped). Pragmatic: gated `llm.object` including
**internal conflict** on policy slices (skills, system, rules) plus **obligation
extraction**; deterministic graph checks on the extracted set (must∧must_not,
system must vs skill may/should, catalog-missing objects). Gate capped at 8.
Set `mode=pragmatic` + catalog `model` for LLM; `mode=deterministic` skips
LLM calls.

## reviewer

You review workflow / skill prose for pragmatic coherence. You receive a slice
body and, for pair reviews, a peer slice body. Selection metadata explains why
the slice was flagged; it is not part of the prose under review.

Rules:
- Judge only text in **Slice under review** and **Peer slice** sections.
- Do not comment on entropy, compression, outliers, or review tooling unless
  those words appear in the slice bodies.
- Felicity violations must cite phrases from the slice bodies.
- Be conservative: only flag issues with evidence in the bodies.
- For `check_internal_conflict`: flag instructions that are **jointly
  unsatisfiable** (cannot both be followed). Conditional alternatives
  ("in situation A … / in situation B …") are OK. Put the two quoted
  instructions in `contradictions[].quote_a` and `contradictions[].quote_b`,
  and a short `why`. If none, return an empty `contradictions` list.
- For other review tasks: same contradiction shape when you find conflicts.
- Always fill `obligations` for normative claims in the slice (empty list if
  none). Each row: `actor`, `modality` exactly one of
  `must` | `should` | `may` | `must_not`, `action`, `object`, optional
  `condition` (empty if unconditioned), and a **verbatim** `quote` from the
  body. Prefer empty list over guessing. Do not invent modules or tools.

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

type Contradiction = {
  quote_a: String,
  quote_b: String,
  why: String
}

type ObligationExtract = {
  actor: String,
  modality: String,
  action: String,
  object: String,
  condition: String,
  quote: String
}

type OblRow = {
  actor: String,
  modality: String,
  action: String,
  object: String,
  condition: String,
  quote: String,
  file: String
}

type ReviewPack = {
  findings: List<Finding>,
  obligations: List<OblRow>
}

type PragmaticOut = {
  illocutionary_force: String,
  felicity_violations: List<String>,
  contradictions: List<Contradiction>,
  clarity_score: Float,
  obligations: List<ObligationExtract>
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
          claim = $"Section word-entropy {s.entropy} above local mean {mean}",
          evidence = $"{s.id} ({s.title})",
          suggestion = "Long or varied prose; inspect only if guidance feels scattered"
        }],
        rest
      )
    else rest

fun sentence_usable(s: String): Bool =
  text.metrics(s).chars > 40

fun redundancy_sent_pairs(sents: List<String>, slice: Slice, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then redundancy_sent_pairs(sents, slice, i + 1, i + 2, n, remaining)
  else
    let a = sents[i]
    let b = sents[j]
    let rest = redundancy_sent_pairs(sents, slice, i, j + 1, n, remaining)
    if not(sentence_usable(a)) then rest
    else if not(sentence_usable(b)) then rest
    else
      let score = text.similarity(a, b)
      if score > 0.9 then
        list.concat(
          [{
            severity = "warning",
            category = "redundancy",
            file = slice.file,
            claim = $"Near-duplicate sentences in {slice.id}",
            evidence = $"A: {a} | B: {b}",
            suggestion = "Keep one wording or merge into a single rule"
          }],
          redundancy_sent_pairs(sents, slice, i, j + 1, n, remaining - 1)
        )
      else rest

fun redundancy_in_slice(slice: Slice, remaining: Int): List<Finding> =
  let sents = text.split_sentences(slice.body)
  redundancy_sent_pairs(sents, slice, 0, 1, list.length(sents), remaining)

fun redundancy_all(slices: List<Slice>, i: Int, n: Int, remaining: Int): List<Finding> =
  if i >= n || remaining <= 0 then []
  else
    let here = redundancy_in_slice(slices[i], remaining)
    let used = list.length(here)
    list.concat(here, redundancy_all(slices, i + 1, n, remaining - used))

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

fun gate_has(xs: List<GateItem>, id: String, rtask: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i].slice_id == id then
    if xs[i].review_task == rtask then true else false
  else gate_has(xs, id, rtask, i + 1, n)

fun gate_append_unique(acc: List<GateItem>, item: GateItem): List<GateItem> =
  if gate_has(acc, item.slice_id, item.review_task, 0, list.length(acc)) then acc
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
    let rest = similarity_gates(slices, i, j + 1, n)
    if not(sentence_usable(a.body)) then rest
    else if not(sentence_usable(b.body)) then rest
    else if text.similarity(a.body, b.body) > 0.85 && not(a.id == b.id) then
      list.concat(
        [{
          slice_id = a.id,
          file = a.file,
          body = a.body,
          gate_source = "redundancy",
          review_task = "check_redundancy",
          peer_file = b.file,
          peer_body = b.body,
          context = $"{a.id} ~ {b.id}",
          priority = 30
        }],
        rest
      )
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

fun is_policy_slice(s: Slice): Bool =
  text.starts_with(s.file, "skills/")
    || text.contains(s.title, "system")
    || text.contains(s.title, "System")
    || text.contains(s.title, "reviewer")
    || text.contains(s.title, "Reviewer")
    || text.contains(s.title, "rules")
    || text.contains(s.title, "Rules")
    || text.contains(s.title, "constraints")
    || text.contains(s.title, "Constraints")

fun policy_gates(slices: List<Slice>, i: Int, n: Int): List<GateItem> =
  if i >= n then []
  else
    let s = slices[i]
    let rest = policy_gates(slices, i + 1, n)
    if not(is_policy_slice(s)) then rest
    else if text.metrics(s.body).chars < 40 then rest
    else
      list.concat(
        [{
          slice_id = s.id,
          file = s.file,
          body = s.body,
          gate_source = "policy",
          review_task = "check_internal_conflict",
          peer_file = "",
          peer_body = "",
          context = "policy surface (skill / system / rules)",
          priority = 15
        }],
        rest
      )

fun build_gate(slices: List<Slice>, prose: List<Finding>, speech: List<Finding>): List<GateItem> =
  let pol = policy_gates(slices, 0, list.length(slices))
  let sp = speech_gates(speech, slices, 0, list.length(speech))
  let pr = prose_gates(prose, slices, 0, list.length(prose))
  let sim = similarity_gates(slices, 0, 1, list.length(slices))
  let merged0 = gate_merge([], pol, 0, list.length(pol))
  let merged1 = gate_merge(merged0, sp, 0, list.length(sp))
  let merged2 = gate_merge(merged1, pr, 0, list.length(pr))
  let merged3 = gate_merge(merged2, sim, 0, list.length(sim))
  take_gates(merged3, 8, 0, list.length(merged3))

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
    if c.quote_a == "" && c.quote_b == "" then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "contradiction",
          file = file,
          claim = if c.why == "" then "Conflicting instructions in gated prose" else c.why,
          evidence = $"A: {c.quote_a} | B: {c.quote_b}",
          suggestion = "Reconcile so both cannot apply in the same case, or remove one"
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

fun stamp_obs(xs: List<ObligationExtract>, file: String, i: Int, n: Int): List<OblRow> =
  if i >= n then []
  else
    let o = xs[i]
    let row = {
      actor = o.actor,
      modality = o.modality,
      action = o.action,
      object = o.object,
      condition = o.condition,
      quote = o.quote,
      file = file
    }
    list.concat([row], stamp_obs(xs, file, i + 1, n))

fun obl_usable(o: OblRow): Bool =
  not(o.quote == "")
    && not(o.modality == "")
    && not(o.action == "")
    && not(o.object == "")

fun same_obl_key(a: OblRow, b: OblRow): Bool =
  a.actor == b.actor && a.action == b.action && a.object == b.object

fun cond_compatible(a: OblRow, b: OblRow): Bool =
  (a.condition == "" && b.condition == "") || a.condition == b.condition

fun is_must_mod(m: String): Bool =
  m == "must" || m == "Must"

fun is_must_not_mod(m: String): Bool =
  m == "must_not"
    || m == "must not"
    || m == "Must not"
    || m == "Must_not"

fun is_soft_mod(m: String): Bool =
  m == "may" || m == "should" || m == "May" || m == "Should"

fun polarity_pair(a: OblRow, b: OblRow): Bool =
  same_obl_key(a, b)
    && cond_compatible(a, b)
    && ((is_must_mod(a.modality) && is_must_not_mod(b.modality))
      || (is_must_not_mod(a.modality) && is_must_mod(b.modality)))

fun soft_pair(a: OblRow, b: OblRow): Bool =
  same_obl_key(a, b)
    && cond_compatible(a, b)
    && ((is_must_mod(a.modality)
      && is_soft_mod(b.modality)
      && text.starts_with(a.file, "workflows/")
      && text.starts_with(b.file, "skills/"))
      || (is_must_mod(b.modality)
        && is_soft_mod(a.modality)
        && text.starts_with(b.file, "workflows/")
        && text.starts_with(a.file, "skills/")))

fun polarity_findings(obs: List<OblRow>, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then polarity_findings(obs, i + 1, i + 2, n, remaining)
  else
    let a = obs[i]
    let b = obs[j]
    let rest = polarity_findings(obs, i, j + 1, n, remaining)
    if not(obl_usable(a)) then rest
    else if not(obl_usable(b)) then rest
    else if not(polarity_pair(a, b)) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "obligation",
          file = a.file,
          claim = $"must vs must_not on ({a.actor}, {a.action}, {a.object})",
          evidence = $"A: {a.quote} ({a.file}) | B: {b.quote} ({b.file})",
          suggestion = "Reconcile modalities across modules or add distinguishing conditions"
        }],
        polarity_findings(obs, i, j + 1, n, remaining - 1)
      )

fun soft_findings(obs: List<OblRow>, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then soft_findings(obs, i + 1, i + 2, n, remaining)
  else
    let a = obs[i]
    let b = obs[j]
    let rest = soft_findings(obs, i, j + 1, n, remaining)
    if not(obl_usable(a)) then rest
    else if not(obl_usable(b)) then rest
    else if not(soft_pair(a, b)) then rest
    else
      list.concat(
        [{
          severity = "info",
          category = "obligation",
          file = a.file,
          claim = $"system must vs skill may/should on ({a.actor}, {a.action}, {a.object})",
          evidence = $"A: {a.quote} ({a.file}) | B: {b.quote} ({b.file})",
          suggestion = "Align skill preference with the system obligation, or scope with a condition"
        }],
        soft_findings(obs, i, j + 1, n, remaining - 1)
      )

fun dead_ref_findings(obs: List<OblRow>, names: List<String>, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let o = obs[i]
    let rest = dead_ref_findings(obs, names, i + 1, n)
    if not(obl_usable(o)) then rest
    else if not(looks_like_qname(o.object)) then rest
    else if has_string(names, o.object, 0, list.length(names)) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "obligation",
          file = o.file,
          claim = "Obligation names a module absent from the catalog",
          evidence = $"quote: {o.quote} | object: {o.object}",
          suggestion = "Add the module or fix the obligation object"
        }],
        rest
      )

fun obligation_graph_findings(obs: List<OblRow>, names: List<String>): List<Finding> =
  let n = list.length(obs)
  let hard = polarity_findings(obs, 0, 1, n, 16)
  let soft = soft_findings(obs, 0, 1, n, 16)
  let dead = dead_ref_findings(obs, names, 0, n)
  concat3(hard, soft, dead)

fun empty_findings(_: Unit): List<Finding> = []

fun empty_obligations(_: Unit): List<OblRow> = []

fun empty_pack(_: Unit): ReviewPack =
  { findings = empty_findings(()), obligations = empty_obligations(()) }

fun review_one_pack(item: GateItem, model: String): ReviewPack =
  let prompt =
    $"{@reviewer}\n\n## Slice under review\nLocation: {item.file}\n\n{item.body}{peer_block(item)}\n\n## Review task\n{item.review_task}\n\n## Context\n{item.context}"
  let out = llm.object(
    prompt = prompt,
    schema = schema(PragmaticOut),
    model = model
  )
  {
    findings = pragmatic_to_findings(out, item),
    obligations = stamp_obs(out.obligations, item.file, 0, list.length(out.obligations))
  }

fun review_all_pack(gate: List<GateItem>, model: String, i: Int, n: Int): ReviewPack =
  if i >= n then empty_pack(())
  else
    let here = review_one_pack(gate[i], model)
    let rest = review_all_pack(gate, model, i + 1, n)
    {
      findings = list.concat(here.findings, rest.findings),
      obligations = list.concat(here.obligations, rest.obligations)
    }

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
  let slices0 = slices_all(paths, 0, npaths)
  let slices = ensure_skill_slices(paths, slices0, 0, npaths)
  let ns = list.length(slices)
  let corpus = list.concat(
    corpus_hints(slices),
    redundancy_all(slices, 0, ns, 16)
  )
  let speech = speech_all(slices, 0, ns)
  let findings = concat4(structural, entry, prose, list.concat(corpus, speech))
  let gate = build_gate(slices, prose, speech)
  let pack =
    if inputs.mode == "pragmatic" then
      review_all_pack(gate, inputs.model, 0, list.length(gate))
    else
      empty_pack(())
  let graph = obligation_graph_findings(pack.obligations, names)
  let pragmatic = list.concat(pack.findings, graph)
  let okv = all_ok(rows, 0, list.length(rows))
  let report_obj = {
    schema = "semantic-report/v1",
    mode = inputs.mode,
    entry = inputs.entry,
    ok = okv,
    review_gate = gate,
    findings = findings,
    obligations = pack.obligations,
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
