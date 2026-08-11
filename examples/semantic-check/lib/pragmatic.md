---
name: lib/pragmatic
effects: [Net]
imports:
  - types/main
---

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

```hwfl
fun has_string(xs: List<String>, q: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i] == q then true
  else has_string(xs, q, i + 1, n)

fun looks_like_qname(tok: String): Bool =
  text.is_qname(tok)

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

fun concat3(a: List<Finding>, b: List<Finding>, c: List<Finding>): List<Finding> =
  list.concat(a, list.concat(b, c))

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
```
