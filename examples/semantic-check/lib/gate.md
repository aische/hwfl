---
name: lib/gate
effects: []
imports:
  - types/main
  - lib/corpus
---

## body

```hwfl
fun concat3(a: List<Finding>, b: List<Finding>, c: List<Finding>): List<Finding> =
  list.concat(list.concat(a, b), c)

fun concat4(a: List<Finding>, b: List<Finding>, c: List<Finding>, d: List<Finding>): List<Finding> =
  list.concat(concat3(a, b, c), d)

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
    if not(lib/corpus.sentence_usable(a.body)) then rest
    else if not(lib/corpus.sentence_usable(b.body)) then rest
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
```
