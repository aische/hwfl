---
name: lib/chapter
effects: [Net, Write, Exec, Read]
imports:
  - types/main
  - lib/kb
  - lib/claims
  - lib/extract
  - lib/util
---

## system

You write clear literary prose matching the requested genre and tone.
Obey the continuity pack and any finding list exactly. No preamble, no
bullet lists, no meta commentary. Keep each chapter roughly 400–800 words
unless the premise asks otherwise.

## body

```hwfl
fun try_commit_extract(
  pid: String,
  ex: ExtractOut,
  ref: String,
  attempt: Int
): AssertResult =
  let delta = lib/extract.extract_to_delta(ex, ref, attempt)
  try
    let dry = lib/kb.assert_delta(pid, "dry_run", delta)
    if dry.ok then
      try
        lib/kb.assert_delta(pid, "commit", delta)
      catch (_err) =>
        lib/kb.host_assert_fail("commit failed")
    else
      dry
  catch (_err) =>
    lib/kb.host_assert_fail("dry_run failed")

fun replace_outline(
  xs: List<ChapterOutline>,
  idx: Int,
  o: ChapterOutline,
  j: Int,
  n: Int
): List<ChapterOutline> =
  if j >= n then []
  else if j == idx then list.concat([o], replace_outline(xs, idx, o, j + 1, n))
  else list.concat([xs[j]], replace_outline(xs, idx, o, j + 1, n))

fun finish_chapter(
  st: ChapterState,
  prose: String,
  findings_path: String,
  committed_ok: Bool,
  caught: Bool,
  chapter_i: Int,
  outlines: List<ChapterOutline>
): ChapterState =
  {
    ok = if committed_ok then st.ok else false,
    committed = if committed_ok then st.committed + 1 else st.committed,
    caught = st.caught || caught,
    findings_path = findings_path,
    last_prose = prose,
    stop = false,
    gaps =
      if committed_ok then st.gaps else list.concat(st.gaps, [chapter_i]),
    outlines = outlines
  }

fun rewrite_chapter_prose(
  model: String,
  pack: String,
  outline: ChapterOutline,
  i: Int,
  prior: String,
  findings_json: String,
  prev_prose: String
): String =
  let beats = lib/util.join_lines(outline.beats, 0, list.length(outline.beats))
  llm.chat(
    system = @system,
    prompt = $"Continuity pack (JSON):\n{pack}\n\nFindings from assert:\n{findings_json}\n\nChapter {i} title: {outline.title}\nSummary: {outline.summary}\nBeats:\n{beats}\nContinuity notes:\n{outline.continuity_notes}\n\nRewrite so findings disappear. One location per character at chapter end. Keep goals.\n\nPrior chapter:\n{prior}\n\nPrevious draft:\n{prev_prose}",
    model = model
  )

fun regen_one_outline(
  model: String,
  outline: ChapterOutline,
  findings_json: String,
  pack: String
): ChapterOutline =
  llm.object(
    prompt = $"Regenerate exactly one chapter outline as ChapterOutline JSON.\nKeep chapter={outline.chapter}. Fix continuity so assert findings can clear.\nFindings:\n{findings_json}\n\nContinuity pack:\n{pack}\n\nPrevious outline:\n{json.encode(outline)}\n\nPrefer fewer simultaneous locations; dead characters must not be located_in.",
    schema = schema(ChapterOutline),
    model = model
  )

fun write_one_chapter(
  pid: String,
  model: String,
  i: Int,
  st: ChapterState
): ChapterState =
  let t = lib/util.chapter_atom(i)
  let pack = lib/kb.pack_markdown(pid)
  let outline = lib/util.outline_at(st.outlines, i, 0, list.length(st.outlines))
  let beats = lib/util.join_lines(outline.beats, 0, list.length(outline.beats))
  let prompt =
    $"Continuity pack (JSON):\n{pack}\n\nChapter {i} title: {outline.title}\nSummary: {outline.summary}\nBeats:\n{beats}\nContinuity notes:\n{outline.continuity_notes}\n\nPrior chapter (tail/context):\n{st.last_prose}\n\nWrite chapter {i} now."
  let draft = llm.chat(system = @system, prompt = prompt, model = model)
  let path = lib/util.chapter_path(i)
  let _ = fs.write(path = path, text = draft)
  let findings_path = $"story/{t}-findings.json"
  let ex1 = lib/extract.extract_claims(model, draft, t, pack)
  let r1 = try_commit_extract(pid, ex1, t, 1)
  let _ = fs.write(path = findings_path, text = json.encode(r1))
  if r1.ok && r1.committed then
    let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
    finish_chapter(st, draft, findings_path, true, false, i, st.outlines)
  else
    let f1 = json.encode(r1.findings)
    let ex2 = lib/extract.repair_extract(model, draft, t, pack, ex1, f1)
    let r2 = try_commit_extract(pid, ex2, t, 2)
    let _ = fs.write(path = findings_path, text = json.encode(r2))
    if r2.ok && r2.committed then
      let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
      finish_chapter(st, draft, findings_path, true, true, i, st.outlines)
    else
      let f2 = json.encode(r2.findings)
      let prose2 = rewrite_chapter_prose(model, pack, outline, i, st.last_prose, f2, draft)
      let _ = fs.write(path = $"story/{t}-regen.md", text = prose2)
      let _ = fs.write(path = path, text = prose2)
      let ex3 = lib/extract.extract_claims(model, prose2, t, pack)
      let r3 = try_commit_extract(pid, ex3, t, 3)
      let _ = fs.write(path = findings_path, text = json.encode(r3))
      if r3.ok && r3.committed then
        let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
        finish_chapter(st, prose2, findings_path, true, true, i, st.outlines)
      else
        let f3 = json.encode(r3.findings)
        let prose3 = rewrite_chapter_prose(model, pack, outline, i, st.last_prose, f3, prose2)
        let _ = fs.write(path = $"story/{t}-regen2.md", text = prose3)
        let _ = fs.write(path = path, text = prose3)
        let ex4 = lib/extract.extract_claims(model, prose3, t, pack)
        let r4 = try_commit_extract(pid, ex4, t, 4)
        let _ = fs.write(path = findings_path, text = json.encode(r4))
        if r4.ok && r4.committed then
          let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
          finish_chapter(st, prose3, findings_path, true, true, i, st.outlines)
        else
          let f4 = json.encode(r4.findings)
          let o2 = regen_one_outline(model, outline, f4, pack)
          let outlines2 = replace_outline(st.outlines, i - 1, o2, 0, list.length(st.outlines))
          let _ = fs.write(
            path = "outlines/chapters.md",
            text = lib/util.format_outlines(outlines2, 0, list.length(outlines2))
          )
          let prose4 = rewrite_chapter_prose(model, pack, o2, i, st.last_prose, f4, prose3)
          let _ = fs.write(path = $"story/{t}-regen-outline.md", text = prose4)
          let _ = fs.write(path = path, text = prose4)
          let ex5 = lib/extract.extract_claims(model, prose4, t, pack)
          let r5 = try_commit_extract(pid, ex5, t, 5)
          let _ = fs.write(path = findings_path, text = json.encode(r5))
          if r5.ok && r5.committed then
            let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
            finish_chapter(st, prose4, findings_path, true, true, i, outlines2)
          else
            finish_chapter(st, prose4, findings_path, false, true, i, outlines2)

fun write_chapters(
  pid: String,
  model: String,
  i: Int,
  n: Int,
  st: ChapterState
): ChapterState =
  if i > n then st
  else
    let next = write_one_chapter(pid, model, i, st)
    write_chapters(pid, model, i + 1, n, next)

fun pass2_one(
  pid: String,
  model: String,
  chapter_i: Int,
  st: ChapterState
): ChapterState =
  let t = lib/util.chapter_atom(chapter_i)
  let path = lib/util.chapter_path(chapter_i)
  let prose = fs.read(path).text
  let pack = lib/kb.pack_markdown(pid)
  let findings_path = $"story/{t}-pass2-findings.json"
  let ex1 = lib/extract.extract_claims(model, prose, t, pack)
  let r1 = try_commit_extract(pid, ex1, $"pass2-{t}", 1)
  let _ = fs.write(path = findings_path, text = json.encode(r1))
  if r1.ok && r1.committed then
    let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
    {
      ok = st.ok,
      committed = st.committed + 1,
      caught = true,
      findings_path = findings_path,
      last_prose = st.last_prose,
      stop = false,
      gaps = st.gaps,
      outlines = st.outlines
    }
  else
    let f1 = json.encode(r1.findings)
    let ex2 = lib/extract.repair_extract(model, prose, t, pack, ex1, f1)
    let r2 = try_commit_extract(pid, ex2, $"pass2-{t}", 2)
    let _ = fs.write(path = findings_path, text = json.encode(r2))
    if r2.ok && r2.committed then
      let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
      {
        ok = st.ok,
        committed = st.committed + 1,
        caught = true,
        findings_path = findings_path,
        last_prose = st.last_prose,
        stop = false,
        gaps = st.gaps,
        outlines = st.outlines
      }
    else
      let outline = lib/util.outline_at(st.outlines, chapter_i, 0, list.length(st.outlines))
      let f2 = json.encode(r2.findings)
      let prose2 = rewrite_chapter_prose(model, pack, outline, chapter_i, st.last_prose, f2, prose)
      let _ = fs.write(path = $"story/{t}-pass2-regen.md", text = prose2)
      let _ = fs.write(path = path, text = prose2)
      let ex3 = lib/extract.extract_claims(model, prose2, t, pack)
      let r3 = try_commit_extract(pid, ex3, $"pass2-{t}", 3)
      let _ = fs.write(path = findings_path, text = json.encode(r3))
      if r3.ok && r3.committed then
        let _ = lib/kb.write_snapshot(pid, $"story/canon-after-{t}.md")
        {
          ok = st.ok,
          committed = st.committed + 1,
          caught = true,
          findings_path = findings_path,
          last_prose = prose2,
          stop = false,
          gaps = st.gaps,
          outlines = st.outlines
        }
      else
        {
          ok = false,
          committed = st.committed,
          caught = true,
          findings_path = findings_path,
          last_prose = prose2,
          stop = false,
          gaps = list.concat(st.gaps, [chapter_i]),
          outlines = st.outlines
        }

fun pass2_gaps(
  pid: String,
  model: String,
  gaps: List<Int>,
  i: Int,
  n: Int,
  st: ChapterState
): ChapterState =
  if i >= n then st
  else
    let next = pass2_one(pid, model, gaps[i], st)
    pass2_gaps(pid, model, gaps, i + 1, n, next)
```
