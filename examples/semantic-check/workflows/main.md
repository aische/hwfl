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
imports:
  - types/main
  - lib/scan
  - lib/structural
  - lib/prose
  - lib/corpus
  - lib/speech
  - lib/contracts
  - lib/gate
  - lib/pragmatic
---

## overview

Semantic review written in hwfl (layers 0–2b + S5 contracts deterministic;
optional same-run layer 3 pragmatic via `llm.object`). Workspace is the target
project. Scans module trees only (`workflows/`, `skills/`, `lib/`, `types/`) —
not README or other docs.

Layer 0 structural: `meta.check_project(".")` when `project.json` exists
(import graph aware); otherwise per-file `meta.check_module` for loose
module trees. Catalog names come from module paths, not check rows.

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

## body

```hwfl
fun main(inputs): { report_path: String, ok: Bool, finding_count: Int } =
  let all_md = fs.find(glob = "**/*.md")
  let paths = lib/scan.filter_module_paths(all_md, 0, list.length(all_md))
  let npaths = list.length(paths)
  let names = lib/scan.path_catalog_names(paths, 0, npaths)
  let has_project = fs.exists("project.json")
  let rows =
    if has_project then lib/structural.empty_rows(())
    else lib/structural.check_paths(paths, 0, npaths)
  let structural =
    if has_project then lib/structural.structural_project()
    else lib/structural.structural_from(rows, 0, list.length(rows))
  let entry = lib/structural.entry_findings(inputs.entry, names)
  let prose = lib/prose.prose_all(paths, names, 0, npaths)
  let slices0 = lib/scan.slices_all(paths, 0, npaths)
  let slices = lib/scan.ensure_skill_slices(paths, slices0, 0, npaths)
  let ns = list.length(slices)
  let corpus = list.concat(
    lib/corpus.corpus_hints(slices),
    lib/corpus.redundancy_all(slices, 0, ns, 16)
  )
  let speech = lib/speech.speech_all(slices, 0, ns)
  let skill_hints = lib/contracts.collect_skill_exec_hints(paths, 0, npaths)
  let contracts = lib/contracts.contracts_all(paths, skill_hints, 0, npaths, 16)
  let findings = list.concat(
    list.concat(list.concat(structural, entry), prose),
    list.concat(list.concat(corpus, speech), contracts)
  )
  let gate = lib/gate.build_gate(slices, prose, speech)
  let pack =
    if inputs.mode == "pragmatic" then
      lib/pragmatic.review_all_pack(gate, inputs.model, 0, list.length(gate))
    else
      lib/pragmatic.empty_pack(())
  let graph = lib/pragmatic.obligation_graph_findings(pack.obligations, names)
  let props = lib/pragmatic.proposition_findings(pack.propositions)
  let pragmatic = list.concat(pack.findings, list.concat(graph, props))
  let okv =
    if has_project then list.length(structural) == 0
    else lib/structural.all_ok(rows, 0, list.length(rows))
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
```
