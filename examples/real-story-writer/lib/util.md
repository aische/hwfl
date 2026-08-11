---
name: lib/util
effects: []
imports:
  - types/main
---

## body

```hwfl
fun empty_entities(_: Unit): List<EntityUpsert> = []

fun empty_aliases(_: Unit): List<AliasUpsert> = []

fun empty_claims(_: Unit): List<ClaimRow> = []

fun empty_ints(_: Unit): List<Int> = []

fun empty_outlines(_: Unit): List<ChapterOutline> = []

fun empty_strings(_: Unit): List<String> = []

fun empty_findings(_: Unit): List<Finding> = []

fun normalize_chapters(n: Int): Int =
  if n < 1 then 3 else n

fun chapter_atom(i: Int): String =
  $"ch{i}"

fun chapter_path(i: Int): String =
  $"story/ch{i}.md"

fun join_lines(xs: List<String>, i: Int, n: Int): String =
  if i >= n then ""
  else if i == n - 1 then xs[i]
  else $"{xs[i]}\n{join_lines(xs, i + 1, n)}"

fun take_claims(xs: List<ClaimRow>, k: Int, i: Int): List<ClaimRow> =
  if i >= k then []
  else if i >= list.length(xs) then []
  else list.concat([xs[i]], take_claims(xs, k, i + 1))

fun retarget_claim(c: ClaimRow, t: String): ClaimRow =
  {
    subject_id = c.subject_id,
    pred = c.pred,
    object_entity_id = c.object_entity_id,
    object_lit = c.object_lit,
    polarity = c.polarity,
    epistemic = c.epistemic,
    t_start = t,
    quote = c.quote
  }

fun retarget_claims(xs: List<ClaimRow>, t: String, i: Int, n: Int): List<ClaimRow> =
  if i >= n then []
  else list.concat([retarget_claim(xs[i], t)], retarget_claims(xs, t, i + 1, n))

fun opt_str(o: Option<String>): String =
  match o with
  | None => ""
  | Some(s) => s

fun format_outline(o: ChapterOutline): String =
  let beats = join_lines(o.beats, 0, list.length(o.beats))
  $"## Chapter {o.chapter}: {o.title}\n\n{o.summary}\n\nBeats:\n{beats}\n\nContinuity:\n{o.continuity_notes}\n"

fun format_outlines(xs: List<ChapterOutline>, i: Int, n: Int): String =
  if i >= n then ""
  else $"{format_outline(xs[i])}\n{format_outlines(xs, i + 1, n)}"

fun outline_at(xs: List<ChapterOutline>, chapter: Int, i: Int, n: Int): ChapterOutline =
  if i >= n then
    {
      chapter = chapter,
      title = $"Chapter {chapter}",
      summary = "Continue the story.",
      beats = ["Advance the plot"],
      continuity_notes = "Obey the continuity pack."
    }
  else if xs[i].chapter == chapter then xs[i]
  else if i == chapter - 1 then xs[i]
  else outline_at(xs, chapter, i + 1, n)
```
