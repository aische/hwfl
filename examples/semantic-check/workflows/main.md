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

Semantic review written in hwfl (layers 0–2b + S5 contracts deterministic;
optional same-run layer 3 pragmatic via `llm.object`). Workspace is the target
project. Scans module trees only (`workflows/`, `skills/`, `lib/`, `types/`) —
not README or other docs.

Deterministic: structural / prose qnames / entropy info / **within-slice
quoted sentence redundancy** (capped) / **prose↔code contracts** (dead
`@section`, effect/tool gaps, schema field vs `outputs:`, skill `exec.run`
vs caller effects; category `contract`, cap 16). Pragmatic: gated `llm.object`
including **internal conflict** on policy slices (skills, system, rules) plus
**obligation extraction** (policy gates only, ≤4 per slice); deterministic
graph checks on the extracted set (must∧must_not, system must vs skill
may/should, catalog-missing objects; ≤12 rows, finding caps 4). Same gates
also emit a **narrow proposition algebra** (`must` / `must_not` / `prefer` /
`prefer_not`, optional condition); deterministic clashes Must∧MustNot and
unconditioned Must vs Prefer(¬a) (category `proposition`; ≤12 rows, caps 4).
Every gated review also assigns an **illocutionary role**
(`System`/`Policy`/`Procedure`/`Example`/`Rationale`/`ToolDoc`) and quotes
role-mismatched sentences; deterministic Policy/System and Example felicity
checks (category `role`). Gate capped at 10. Set `mode=pragmatic` + catalog
`model` for LLM; `mode=deterministic` skips LLM calls.

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
- Always fill `obligations` for normative claims when the review task is
  `check_internal_conflict` (empty list otherwise). Each row: `actor`,
  `modality` exactly one of `must` | `should` | `may` | `must_not`,
  `action`, `object`, optional `condition` (empty if unconditioned), and a
  **verbatim** `quote` from the body. Prefer a short list (≤8) over guessing.
  Do not invent modules or tools.
- On the same task, also fill `propositions`: a narrow projection of those
  norms. Each row: `form` exactly one of `must` | `must_not` | `prefer` |
  `prefer_not`, short `atom` (shared key for clashes, e.g. `use lib/search`),
  optional `condition` (empty if unconditioned; non-empty means If(c, …)),
  and a **verbatim** `quote`. Use `prefer_not` for soft preferences against
  an atom (Prefer(¬a)). Empty list when the task is not
  `check_internal_conflict`. Prefer ≤8 rows; do not invent atoms.
- Always set `role` to exactly one of: `System` | `Policy` | `Procedure` |
  `Example` | `Rationale` | `ToolDoc`. Choose the dominant speech-act of the
  slice (skills/rules → `Policy`; agent/system prompts → `System`; how-to
  steps → `Procedure`; sample sessions → `Example`; why-prose → `Rationale`;
  tool/API docs → `ToolDoc`).
- Fill `mismatched_sentences` with body sentences that break that role
  (e.g. hard `must`/`never` constraints inside an `Example`, or vibe-only
  advice inside `Policy`). Each row needs a **verbatim** `quote` and short
  `why`. Empty list if the slice fits its role.

## body

````hwfl
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

type RoleMismatch = {
  quote: String,
  why: String
}

type RoleRow = {
  role: String,
  file: String,
  slice_id: String
}

type PropExtract = {
  form: String,
  atom: String,
  condition: String,
  quote: String
}

type PropRow = {
  form: String,
  atom: String,
  condition: String,
  quote: String,
  file: String
}

type SkillExecHint = {
  id: String,
  file: String,
  quote: String
}

type ReviewPack = {
  findings: List<Finding>,
  obligations: List<OblRow>,
  propositions: List<PropRow>,
  roles: List<RoleRow>
}

type PragmaticOut = {
  illocutionary_force: String,
  felicity_violations: List<String>,
  contradictions: List<Contradiction>,
  clarity_score: Float,
  obligations: List<ObligationExtract>,
  propositions: List<PropExtract>,
  role: String,
  mismatched_sentences: List<RoleMismatch>
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
  take_gates(merged3, 10, 0, list.length(merged3))

fun bleed_felicity(s: String): Bool =
  text.contains(s, "entropy")
    || text.contains(s, "outlier")
    || text.contains(s, "compression")
    || text.contains(s, "review_gate")

fun felicity_findings(xs: List<String>, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let s = xs[i]
    if bleed_felicity(s) then felicity_findings(xs, file, i + 1, n, remaining)
    else if s == "" then felicity_findings(xs, file, i + 1, n, remaining)
    else if i >= 32 then []
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
        felicity_findings(xs, file, i + 1, n, remaining - 1)
      )

fun contradiction_findings(xs: List<Contradiction>, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let c = xs[i]
    if c.quote_a == "" && c.quote_b == "" then
      contradiction_findings(xs, file, i + 1, n, remaining)
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
        contradiction_findings(xs, file, i + 1, n, remaining - 1)
      )

fun is_policy_role(r: String): Bool =
  r == "Policy" || r == "policy" || r == "System" || r == "system"

fun is_example_role(r: String): Bool =
  r == "Example" || r == "example"

fun normalize_role(r: String): String =
  if r == "System" || r == "system" then "System"
  else if r == "Policy" || r == "policy" then "Policy"
  else if r == "Procedure" || r == "procedure" then "Procedure"
  else if r == "Example" || r == "example" then "Example"
  else if r == "Rationale" || r == "rationale" then "Rationale"
  else if r == "ToolDoc" || r == "tooldoc" || r == "Tooldoc" then "ToolDoc"
  else if r == "" then "Unknown"
  else "Unknown"

fun any_directive(sents: List<String>, i: Int, n: Int): Bool =
  if i >= n then false
  else if is_directive(sents[i]) then true
  else any_directive(sents, i + 1, n)

fun body_has_directive(body: String): Bool =
  let sents = text.split_sentences(body)
  any_directive(sents, 0, list.length(sents))

fun example_marked(s: String): Bool =
  text.contains(s, "example")
    || text.contains(s, "Example")
    || text.contains(s, "illustrat")
    || text.contains(s, "Illustrat")
    || text.contains(s, "for instance")
    || text.contains(s, "sample")
    || text.contains(s, "Sample")
    || text.contains(s, "normative")
    || text.contains(s, "Normative")

fun role_mismatch_findings(xs: List<RoleMismatch>, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let m = xs[i]
    if m.quote == "" then role_mismatch_findings(xs, file, i + 1, n, remaining)
    else if i >= 16 then []
    else
      list.concat(
        [{
          severity = "warning",
          category = "role",
          file = file,
          claim = if m.why == "" then "Sentence does not fit the assigned illocutionary role" else m.why,
          evidence = m.quote,
          suggestion = "Move the sentence to a matching section, or mark it as normative/example explicitly"
        }],
        role_mismatch_findings(xs, file, i + 1, n, remaining - 1)
      )

fun role_policy_findings(role: String, body: String, file: String, slice_id: String): List<Finding> =
  if not(is_policy_role(role)) then []
  else if body_has_directive(body) then []
  else
    [{
      severity = "warning",
      category = "role",
      file = file,
      claim = "Policy/System role lacks directive language",
      evidence = slice_id,
      suggestion = "Add explicit must/should/never guidance, or retitle as Rationale/Example"
    }]

fun example_constraint_sents(sents: List<String>, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let sent = sents[i]
    let rest = example_constraint_sents(sents, file, i + 1, n, remaining)
    if not(is_directive(sent)) then rest
    else if example_marked(sent) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "role",
          file = file,
          claim = "Hard constraint inside an Example role",
          evidence = sent,
          suggestion = "Move normative rules to Policy/System, or mark the sentence as illustrative only"
        }],
        example_constraint_sents(sents, file, i + 1, n, remaining - 1)
      )

fun role_example_findings(role: String, body: String, file: String): List<Finding> =
  if not(is_example_role(role)) then []
  else
    let sents = text.split_sentences(body)
    example_constraint_sents(sents, file, 0, list.length(sents), 4)

fun role_findings(out: PragmaticOut, item: GateItem): List<Finding> =
  let role = normalize_role(out.role)
  let quoted = role_mismatch_findings(
    out.mismatched_sentences,
    item.file,
    0,
    list.length(out.mismatched_sentences),
    4
  )
  let policy = role_policy_findings(role, item.body, item.file, item.slice_id)
  let example = role_example_findings(role, item.body, item.file)
  concat3(quoted, policy, example)

fun pragmatic_to_findings(out: PragmaticOut, item: GateItem): List<Finding> =
  concat3(
    felicity_findings(out.felicity_violations, item.file, 0, list.length(out.felicity_violations), 4),
    contradiction_findings(out.contradictions, item.file, 0, list.length(out.contradictions), 4),
    role_findings(out, item)
  )

fun peer_block(item: GateItem): String =
  if item.peer_body == "" then ""
  else $"\n\n## Peer slice\nLocation: {item.peer_file}\n\n{item.peer_body}"

fun stamp_obs(xs: List<ObligationExtract>, file: String, i: Int, n: Int, remaining: Int): List<OblRow> =
  if remaining <= 0 then []
  else if i >= n then []
  else if i >= 16 then []
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
    if not(obl_usable(row)) then stamp_obs(xs, file, i + 1, n, remaining)
    else list.concat([row], stamp_obs(xs, file, i + 1, n, remaining - 1))

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
    if not(polarity_pair(a, b)) then polarity_findings(obs, i, j + 1, n, remaining)
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
    if not(soft_pair(a, b)) then soft_findings(obs, i, j + 1, n, remaining)
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

fun dead_ref_findings(obs: List<OblRow>, names: List<String>, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let o = obs[i]
    if not(looks_like_qname(o.object)) then dead_ref_findings(obs, names, i + 1, n, remaining)
    else if has_string(names, o.object, 0, list.length(names)) then
      dead_ref_findings(obs, names, i + 1, n, remaining)
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
        dead_ref_findings(obs, names, i + 1, n, remaining - 1)
      )

fun take_obs(xs: List<OblRow>, k: Int, i: Int, n: Int): List<OblRow> =
  if i >= n || k <= 0 then []
  else list.concat([xs[i]], take_obs(xs, k - 1, i + 1, n))

fun obligation_graph_findings(obs: List<OblRow>, names: List<String>): List<Finding> =
  let capped = take_obs(obs, 12, 0, list.length(obs))
  let n = list.length(capped)
  let hard = polarity_findings(capped, 0, 1, n, 4)
  let soft =
    if n > 8 then empty_findings(())
    else soft_findings(capped, 0, 1, n, 4)
  let dead = dead_ref_findings(capped, names, 0, n, 4)
  concat3(hard, soft, dead)

fun normalize_atom(a: String): String =
  text.trim(a)

fun normalize_prop_form(f: String): String =
  if f == "Must" then "must"
  else if f == "MustNot" || f == "must not" || f == "Must_not" then "must_not"
  else if f == "Prefer" then "prefer"
  else if f == "PreferNot" || f == "prefer not" || f == "Prefer_not" then "prefer_not"
  else if f == "If" || f == "if_must" then "must"
  else f

fun prop_usable(p: PropRow): Bool =
  not(p.quote == "")
    && not(p.atom == "")
    && not(p.form == "")

fun stamp_props(xs: List<PropExtract>, file: String, i: Int, n: Int, remaining: Int): List<PropRow> =
  if remaining <= 0 then []
  else if i >= n then []
  else if i >= 16 then []
  else
    let x = xs[i]
    let row = {
      form = normalize_prop_form(x.form),
      atom = normalize_atom(x.atom),
      condition = x.condition,
      quote = x.quote,
      file = file
    }
    if not(prop_usable(row)) then stamp_props(xs, file, i + 1, n, remaining)
    else list.concat([row], stamp_props(xs, file, i + 1, n, remaining - 1))

fun obl_to_prop_form(m: String): String =
  if is_must_mod(m) then "must"
  else if is_must_not_mod(m) then "must_not"
  else if is_soft_mod(m) then "prefer"
  else ""

fun project_one_obl(o: OblRow): List<PropRow> =
  let form = obl_to_prop_form(o.modality)
  if form == "" then []
  else
    [{
      form = form,
      atom = normalize_atom($"{o.action} {o.object}"),
      condition = o.condition,
      quote = o.quote,
      file = o.file
    }]

fun project_props_from_obs(obs: List<OblRow>, i: Int, n: Int, remaining: Int): List<PropRow> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let here = project_one_obl(obs[i])
    let used = list.length(here)
    list.concat(here, project_props_from_obs(obs, i + 1, n, remaining - used))

fun prop_has_key(xs: List<PropRow>, form: String, atom: String, cond: String, file: String, i: Int, n: Int): Bool =
  if i >= n then false
  else
    let p = xs[i]
    if p.form == form && p.atom == atom && p.condition == cond && p.file == file then true
    else prop_has_key(xs, form, atom, cond, file, i + 1, n)

fun merge_prop(acc: List<PropRow>, p: PropRow): List<PropRow> =
  if prop_has_key(acc, p.form, p.atom, p.condition, p.file, 0, list.length(acc)) then acc
  else list.concat(acc, [p])

fun merge_props(acc: List<PropRow>, xs: List<PropRow>, i: Int, n: Int): List<PropRow> =
  if i >= n then acc
  else merge_props(merge_prop(acc, xs[i]), xs, i + 1, n)

fun take_props(xs: List<PropRow>, k: Int, i: Int, n: Int): List<PropRow> =
  if i >= n || k <= 0 then []
  else list.concat([xs[i]], take_props(xs, k - 1, i + 1, n))

fun same_prop_atom(a: PropRow, b: PropRow): Bool =
  a.atom == b.atom

fun prop_cond_compatible(a: PropRow, b: PropRow): Bool =
  (a.condition == "" && b.condition == "") || a.condition == b.condition

fun is_must_form(f: String): Bool =
  f == "must"

fun is_must_not_form(f: String): Bool =
  f == "must_not"

fun is_prefer_not_form(f: String): Bool =
  f == "prefer_not"

fun prop_polarity_pair(a: PropRow, b: PropRow): Bool =
  same_prop_atom(a, b)
    && prop_cond_compatible(a, b)
    && ((is_must_form(a.form) && is_must_not_form(b.form))
      || (is_must_not_form(a.form) && is_must_form(b.form)))

fun prop_prefer_clash(a: PropRow, b: PropRow): Bool =
  same_prop_atom(a, b)
    && a.condition == ""
    && b.condition == ""
    && ((is_must_form(a.form) && is_prefer_not_form(b.form))
      || (is_prefer_not_form(a.form) && is_must_form(b.form)))

fun prop_polarity_findings(ps: List<PropRow>, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then prop_polarity_findings(ps, i + 1, i + 2, n, remaining)
  else
    let a = ps[i]
    let b = ps[j]
    if not(prop_polarity_pair(a, b)) then prop_polarity_findings(ps, i, j + 1, n, remaining)
    else
      list.concat(
        [{
          severity = "warning",
          category = "proposition",
          file = a.file,
          claim = $"Must(a) vs MustNot(a) on atom `{a.atom}`",
          evidence = $"A: {a.quote} ({a.file}) | B: {b.quote} ({b.file})",
          suggestion = "Reconcile hard norms or scope with distinguishing conditions"
        }],
        prop_polarity_findings(ps, i, j + 1, n, remaining - 1)
      )

fun prop_prefer_findings(ps: List<PropRow>, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then prop_prefer_findings(ps, i + 1, i + 2, n, remaining)
  else
    let a = ps[i]
    let b = ps[j]
    if not(prop_prefer_clash(a, b)) then prop_prefer_findings(ps, i, j + 1, n, remaining)
    else
      list.concat(
        [{
          severity = "warning",
          category = "proposition",
          file = a.file,
          claim = $"Must(a) vs Prefer(~a) on atom `{a.atom}`",
          evidence = $"A: {a.quote} ({a.file}) | B: {b.quote} ({b.file})",
          suggestion = "Drop the soft preference against a required atom, or weaken the must"
        }],
        prop_prefer_findings(ps, i, j + 1, n, remaining - 1)
      )

fun proposition_findings(ps: List<PropRow>): List<Finding> =
  let capped = take_props(ps, 12, 0, list.length(ps))
  let n = list.length(capped)
  let hard = prop_polarity_findings(capped, 0, 1, n, 4)
  let soft = prop_prefer_findings(capped, 0, 1, n, 4)
  list.concat(hard, soft)

fun empty_findings(_: Unit): List<Finding> = []

fun empty_obligations(_: Unit): List<OblRow> = []

fun empty_propositions(_: Unit): List<PropRow> = []

fun empty_roles(_: Unit): List<RoleRow> = []

fun empty_pack(_: Unit): ReviewPack =
  {
    findings = empty_findings(()),
    obligations = empty_obligations(()),
    propositions = empty_propositions(()),
    roles = empty_roles(())
  }

fun wants_obligations(item: GateItem): Bool =
  item.review_task == "check_internal_conflict"

fun stamp_role(role: String, item: GateItem): RoleRow =
  {
    role = normalize_role(role),
    file = item.file,
    slice_id = item.slice_id
  }

fun review_one_pack(item: GateItem, model: String): ReviewPack =
  let prompt =
    $"{@reviewer}\n\n## Slice under review\nLocation: {item.file}\n\n{item.body}{peer_block(item)}\n\n## Review task\n{item.review_task}\n\n## Context\n{item.context}"
  let out = llm.object(
    prompt = prompt,
    schema = schema(PragmaticOut),
    model = model
  )
  let obs =
    if wants_obligations(item) then
      stamp_obs(out.obligations, item.file, 0, list.length(out.obligations), 4)
    else
      empty_obligations(())
  let from_llm =
    if wants_obligations(item) then
      stamp_props(out.propositions, item.file, 0, list.length(out.propositions), 4)
    else
      empty_propositions(())
  let from_obs = project_props_from_obs(obs, 0, list.length(obs), 4)
  let props = merge_props(from_obs, from_llm, 0, list.length(from_llm))
  {
    findings = pragmatic_to_findings(out, item),
    obligations = obs,
    propositions = props,
    roles = [stamp_role(out.role, item)]
  }

fun review_all_pack(gate: List<GateItem>, model: String, i: Int, n: Int): ReviewPack =
  if i >= n then empty_pack(())
  else
    let here = review_one_pack(gate[i], model)
    let rest = review_all_pack(gate, model, i + 1, n)
    {
      findings = list.concat(here.findings, rest.findings),
      obligations = list.concat(here.obligations, rest.obligations),
      propositions = list.concat(here.propositions, rest.propositions),
      roles = list.concat(here.roles, rest.roles)
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

fun has_hwfl_fence(raw: String): Bool =
  text.contains(raw, "```hwfl")

fun is_bindable_slug(slug: String): Bool =
  slug == "system"
    || slug == "agent"
    || slug == "reviewer"
    || slug == "prompt"
    || slug == "user"
    || slug == "instructions"

fun has_effect_token(raw: String, eff: String): Bool =
  text.contains(raw, $"[{eff}]")
    || text.contains(raw, $"[{eff},")
    || text.contains(raw, $", {eff},")
    || text.contains(raw, $", {eff}]")

fun has_tools_list(raw: String): Bool =
  text.contains(raw, "tools =") || text.contains(raw, "tools=")

fun concat_sec_bodies(secs: List<{ slug: String, title: String, body: String }>, i: Int, n: Int): String =
  if i >= n then ""
  else $"{secs[i].body}\n{concat_sec_bodies(secs, i + 1, n)}"

fun dead_section_one(s: { slug: String, title: String, body: String }, raw: String, file: String): List<Finding> =
  if not(is_bindable_slug(s.slug)) then []
  else if text.metrics(s.body).chars < 40 then []
  else if not(has_hwfl_fence(raw)) then []
  else if text.contains(raw, $"@{s.slug}") then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Bindable section @{s.slug} is never interpolated",
      evidence = s.title,
      suggestion = $"Reference @{s.slug} from the hwfl fence, or rename the section to plain docs"
    }]

fun dead_section_findings(secs: List<{ slug: String, title: String, body: String }>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let here = dead_section_one(secs[i], raw, file)
    let used = list.length(here)
    list.concat(here, dead_section_findings(secs, raw, file, i + 1, n, remaining - used))

fun effect_gap_one(prose: String, raw: String, file: String, needle: String, eff: String): List<Finding> =
  if not(text.contains(prose, needle)) then []
  else if has_effect_token(raw, eff) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Prose names {needle} but effects lack {eff}",
      evidence = needle,
      suggestion = $"Add {eff} to frontmatter effects, or remove the prose claim"
    }]

fun tool_gap_one(prose: String, raw: String, file: String, needle: String, tool_expr: String): List<Finding> =
  if not(has_tools_list(raw)) then []
  else if not(text.contains(prose, needle)) then []
  else if text.contains(raw, tool_expr) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Prose names {needle} but tools list lacks {tool_expr}",
      evidence = needle,
      suggestion = $"Add {tool_expr} to tools, or remove the prose claim"
    }]

fun effect_tool_gaps(prose: String, raw: String, file: String): List<Finding> =
  if not(has_hwfl_fence(raw)) then empty_findings(())
  else
    concat4(
      list.concat(
        effect_gap_one(prose, raw, file, "exec.run", "Exec"),
        effect_gap_one(prose, raw, file, "exec_run", "Exec")
      ),
      list.concat(
        effect_gap_one(prose, raw, file, "fs.write", "Write"),
        list.concat(
          effect_gap_one(prose, raw, file, "fs_write", "Write"),
          list.concat(
            effect_gap_one(prose, raw, file, "fs.patch", "Write"),
            effect_gap_one(prose, raw, file, "fs_patch", "Write")
          )
        )
      ),
      list.concat(
        effect_gap_one(prose, raw, file, "llm.chat", "Net"),
        list.concat(
          effect_gap_one(prose, raw, file, "llm.object", "Net"),
          effect_gap_one(prose, raw, file, "llm.agent", "Net")
        )
      ),
      list.concat(
        tool_gap_one(prose, raw, file, "exec.run", "tool(exec.run)"),
        list.concat(
          tool_gap_one(prose, raw, file, "exec_run", "tool(exec.run)"),
          list.concat(
            tool_gap_one(prose, raw, file, "fs.write", "tool(fs.write)"),
            list.concat(
              tool_gap_one(prose, raw, file, "fs_write", "tool(fs.write)"),
              list.concat(
                tool_gap_one(prose, raw, file, "fs.patch", "tool(fs.patch)"),
                tool_gap_one(prose, raw, file, "fs_patch", "tool(fs.patch)")
              )
            )
          )
        )
      )
    )

fun is_schema_section(title: String): Bool =
  text.contains(title, "schema") || text.contains(title, "Schema")

fun is_type_name(s: String): Bool =
  s == "String"
    || s == "Bool"
    || s == "Int"
    || s == "Float"
    || s == "List"
    || s == "FileRef"
    || s == "Unit"
    || s == "Json"

fun has_output_field(raw: String, field: String): Bool =
  text.contains(raw, $"{field}: String")
    || text.contains(raw, $"{field}: Bool")
    || text.contains(raw, $"{field}: Int")
    || text.contains(raw, $"{field}: Float")
    || text.contains(raw, $"{field}: List")
    || text.contains(raw, $"{field}: FileRef")
    || text.contains(raw, $"{field}: Unit")
    || text.contains(raw, $"{field}: Json")

fun field_label_token(tok: String): String =
  if not(text.contains(tok, ":")) then ""
  else
    let name = text.normalize_token(tok)
    if name == "" then ""
    else if is_type_name(name) then ""
    else if text.contains(name, "/") then ""
    else if text.contains(name, ".") then ""
    else if text.metrics(name).chars < 2 then ""
    else if text.metrics(name).chars > 32 then ""
    else name

fun output_gap_from_words(words: List<String>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let name = field_label_token(words[i])
    let rest = output_gap_from_words(words, raw, file, i + 1, n, remaining)
    if name == "" then rest
    else if has_output_field(raw, name) then rest
    else if not(text.contains(raw, "outputs:")) then rest
    else
      list.concat(
        [{
          severity = "warning",
          category = "contract",
          file = file,
          claim = $"Schema prose promises field absent from outputs: {name}",
          evidence = name,
          suggestion = $"Add {name} to frontmatter outputs, or drop it from the schema section"
        }],
        output_gap_from_words(words, raw, file, i + 1, n, remaining - 1)
      )

fun output_gap_sections(secs: List<{ slug: String, title: String, body: String }>, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let s = secs[i]
    let here =
      if not(is_schema_section(s.title)) then empty_findings(())
      else
        let words = text.words(s.body)
        output_gap_from_words(words, raw, file, 0, list.length(words), remaining)
    let used = list.length(here)
    list.concat(here, output_gap_sections(secs, raw, file, i + 1, n, remaining - used))

fun recommends_exec(body: String): Bool =
  text.contains(body, "exec.run") || text.contains(body, "exec_run")

fun skill_exec_quote(body: String): String =
  if text.contains(body, "exec.run") then "exec.run"
  else if text.contains(body, "exec_run") then "exec_run"
  else "exec"

fun path_to_qname(path_s: String): String =
  text.strip_suffix(path_s, ".md")

fun collect_skill_exec_hints(paths: List<FileRef>, i: Int, n: Int): List<SkillExecHint> =
  if i >= n then []
  else
    let p = paths[i]
    let path_s = $"{p}"
    let rest = collect_skill_exec_hints(paths, i + 1, n)
    if not(text.starts_with(path_s, "skills/")) then rest
    else
      let contents = fs.read(p)
      if not(recommends_exec(contents.text)) then rest
      else
        list.concat(
          [{
            id = path_to_qname(path_s),
            file = path_s,
            quote = skill_exec_quote(contents.text)
          }],
          rest
        )

fun skill_caller_gap_one(hint: SkillExecHint, prose: String, raw: String, file: String): List<Finding> =
  if has_effect_token(raw, "Exec") then []
  else if not(text.contains(prose, hint.id)) then []
  else
    [{
      severity = "warning",
      category = "contract",
      file = file,
      claim = $"Caller lacks Exec but references skill that recommends {hint.quote}",
      evidence = $"skill={hint.id} quote={hint.quote}",
      suggestion = "Add Exec to caller effects, or stop naming that skill from this module"
    }]

fun skill_caller_gaps_hints(hints: List<SkillExecHint>, prose: String, raw: String, file: String, i: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else
    let here = skill_caller_gap_one(hints[i], prose, raw, file)
    let used = list.length(here)
    list.concat(here, skill_caller_gaps_hints(hints, prose, raw, file, i + 1, n, remaining - used))

fun contract_file(path: FileRef, hints: List<SkillExecHint>, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else
    let contents = fs.read(path)
    let raw = contents.text
    let path_s = $"{path}"
    let secs = md.sections(raw)
    let prose = concat_sec_bodies(secs, 0, list.length(secs))
    let dead = dead_section_findings(secs, raw, path_s, 0, list.length(secs), remaining)
    let rem1 = remaining - list.length(dead)
    let gaps = effect_tool_gaps(prose, raw, path_s)
    let rem2 = rem1 - list.length(gaps)
    let outs = output_gap_sections(secs, raw, path_s, 0, list.length(secs), rem2)
    let rem3 = rem2 - list.length(outs)
    let cross =
      if text.starts_with(path_s, "workflows/") then
        skill_caller_gaps_hints(hints, prose, raw, path_s, 0, list.length(hints), rem3)
      else empty_findings(())
    concat4(dead, gaps, outs, cross)

fun contracts_all(paths: List<FileRef>, hints: List<SkillExecHint>, i: Int, n: Int, remaining: Int): List<Finding> =
  if i >= n || remaining <= 0 then []
  else
    let here = contract_file(paths[i], hints, remaining)
    let used = list.length(here)
    list.concat(here, contracts_all(paths, hints, i + 1, n, remaining - used))

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
  let skill_hints = collect_skill_exec_hints(paths, 0, npaths)
  let contracts = contracts_all(paths, skill_hints, 0, npaths, 16)
  let findings = concat4(
    structural,
    entry,
    prose,
    list.concat(list.concat(corpus, speech), contracts)
  )
  let gate = build_gate(slices, prose, speech)
  let pack =
    if inputs.mode == "pragmatic" then
      review_all_pack(gate, inputs.model, 0, list.length(gate))
    else
      empty_pack(())
  let graph = obligation_graph_findings(pack.obligations, names)
  let props = proposition_findings(pack.propositions)
  let pragmatic = list.concat(pack.findings, list.concat(graph, props))
  let okv = all_ok(rows, 0, list.length(rows))
  let report_obj = {
    schema = "semantic-report/v1",
    mode = inputs.mode,
    entry = inputs.entry,
    ok = okv,
    review_gate = gate,
    findings = findings,
    obligations = pack.obligations,
    propositions = pack.propositions,
    roles = pack.roles,
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
````
