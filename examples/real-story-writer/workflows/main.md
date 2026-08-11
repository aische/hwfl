---
name: workflows/main
inputs:
    mode: String
    premise: String
    chapters: Int
    model: String
    project_id: String
    title: String
    strict_kb: Bool
outputs:
    ok: Bool
    project_id: String
    title: String
    chapters_requested: Int
    chapters_committed: Int
    contradiction_caught: Bool
    findings_path: String
    bible_path: String
    outlines_path: String
    snapshot_path: String
    report: String
effects: [Human, Read, Write, Net, Exec]
examples:
    - name: smoke
      inputs:
          mode: smoke
          premise: ""
          chapters: 3
          model: deepseek4flash
          project_id: real-story-smoke
          title: ""
          strict_kb: false
imports:
  - types/main
  - lib/util
  - lib/kb
  - lib/claims
  - lib/bible
  - lib/extract
  - lib/chapter
  - lib/smoke
---

## overview

Multi-chapter story pipeline against external **kb-mcp** (`fiction.v1`).

- `mode=smoke` — no LLM: multi-chapter hard-coded deltas, planted
  continuity clash dry_run → regen/commit, growing snapshots.
- `mode=live` — premise → bible → outlines → per chapter layered repair:
  sanitize extract → dry_run/commit → extract-only repair → chapter
  rewrite (×2) → outline regen + rewrite → else `kb_gap` and continue.
  Pass-2 retries gaps. `strict_kb=true` ⇒ `ok` only if every chapter
  committed. Never silent-commit dirty deltas.

`examples/story-writer` remains the MCP regression fixture; this project
is the real multi-chapter path.

KB: workspace `.kb/story.sqlite`. Prose: `story/`, `outlines/`.

## outlines-prompt

Produce exactly N chapter outlines (chapter field 1..N in order). Each
outline: title, summary, beats (3–6 short strings), continuity_notes
(constraints the prose must obey given the bible). No claim rows here.

## body

```hwfl
fun resolve_premise(mode: String, premise: String): String =
  if mode != "live" then premise
  else if premise != "" then premise
  else
    human.ask({
      prompt = "Premise>",
      detail = "Describe the story you want (genre, tone, length hint, must-haves)."
    })

fun run_live(
  pid: String,
  model: String,
  premise: String,
  chapters: Int,
  title_in: String,
  strict_kb: Bool
): Out =
  let n = lib/util.normalize_chapters(chapters)
  let _ = lib/kb.ensure_project(pid)
  let _ = fs.mkdir("story")
  let _ = fs.mkdir("outlines")
  let title_hint =
    if title_in == "" then "(invent a fitting title)" else title_in
  let bible0 = lib/bible.from_llm_bible(
    llm.object(
      prompt = $"{@bible-prompt}\n\nDesired title hint: {title_hint}\nChapter count target: {n}\n\nPremise:\n{premise}",
      schema = schema(LlmBible),
      model = model
    )
  )
  let story_title =
    if title_in != "" then title_in
    else if bible0.title != "" then bible0.title
    else "Untitled"
  let bible = lib/bible.with_title(bible0, story_title)
  let bible_path = lib/bible.write_bible_md(bible, "story/bible.md")
  let seed = lib/bible.commit_or_repair_bible(pid, model, premise, title_hint, n, bible)
  if not(seed.assert.ok) || not(seed.assert.committed) then
    let snap_path = lib/kb.write_snapshot(pid, "story/canon.md")
    let findings_path = "story/bible-findings.json"
    {
      ok = false,
      project_id = pid,
      title = story_title,
      chapters_requested = n,
      chapters_committed = 0,
      contradiction_caught = seed.regenerated,
      findings_path = findings_path,
      bible_path = bible_path,
      outlines_path = "",
      snapshot_path = snap_path,
      report = $"live failed: bible assert did not commit; regen={seed.regenerated}; findings={json.encode(seed.assert.findings)}"
    }
  else
    let canon_bible = seed.bible
    let outlines = llm.object(
      prompt = $"{@outlines-prompt}\n\nProduce exactly {n} chapters.\n\nTitle: {story_title}\nSynopsis: {canon_bible.synopsis}\nSetting: {canon_bible.setting}\nEntities: {json.encode(canon_bible.entities)}\nPremise:\n{premise}",
      schema = schema(OutlinesOut),
      model = model
    )
    let outlines_path = "outlines/chapters.md"
    let _ = fs.write(
      path = outlines_path,
      text = lib/util.format_outlines(outlines.chapters, 0, list.length(outlines.chapters))
    )
    let st0 = {
      ok = true,
      committed = 0,
      caught = false,
      findings_path = "",
      last_prose = "(no prior chapter)",
      stop = false,
      gaps = lib/util.empty_ints(()),
      outlines = outlines.chapters
    }
    let st1 = lib/chapter.write_chapters(pid, model, 1, n, st0)
    let gaps1 = st1.gaps
    let _ = fs.write(path = "story/kb-gaps.json", text = json.encode(gaps1))
    let st2 =
      if list.length(gaps1) == 0 then
        st1
      else
        let cleared = {
          ok = st1.ok,
          committed = st1.committed,
          caught = st1.caught,
          findings_path = st1.findings_path,
          last_prose = st1.last_prose,
          stop = false,
          gaps = lib/util.empty_ints(()),
          outlines = st1.outlines
        }
        lib/chapter.pass2_gaps(pid, model, gaps1, 0, list.length(gaps1), cleared)
    let _ = fs.write(path = "story/kb-gaps.json", text = json.encode(st2.gaps))
    let snap_path = lib/kb.write_snapshot(pid, "story/canon.md")
    let kb_complete = st2.committed == n && list.length(st2.gaps) == 0
    let ok = if strict_kb then kb_complete else true
    let report =
      $"live done: wrote {n} chapters; kb_committed={st2.committed}/{n}; gaps={json.encode(st2.gaps)}; bible_regen={seed.regenerated}; issues={st2.caught}; strict_kb={strict_kb}; findings={st2.findings_path}"
    {
      ok = ok,
      project_id = pid,
      title = story_title,
      chapters_requested = n,
      chapters_committed = st2.committed,
      contradiction_caught = seed.regenerated || st2.caught,
      findings_path = st2.findings_path,
      bible_path = bible_path,
      outlines_path = outlines_path,
      snapshot_path = snap_path,
      report = report
    }

fun main(inputs): Out =
  let pid =
    if inputs.project_id == "" then "real-story" else inputs.project_id
  let mode =
    if inputs.mode == "" then "smoke" else inputs.mode
  if mode == "live" then
    let premise = resolve_premise(mode, inputs.premise)
    run_live(pid, inputs.model, premise, inputs.chapters, inputs.title, inputs.strict_kb)
  else
    lib/smoke.run_smoke(pid)
```
