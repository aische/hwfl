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
---

## overview

Product-demo story pipeline against external **kb-mcp** (`fiction.v1`).

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

## system

You write clear literary prose matching the requested genre and tone.
Obey the continuity pack and any finding list exactly. No preamble, no
bullet lists, no meta commentary. Keep each chapter roughly 400–800 words
unless the premise asks otherwise.

## bible-prompt

Build a story bible as structured data for fiction.v1.

Entity ids MUST be stable slugs: `char:…`, `place:…`, `faction:…`,
`obj:…`, `creature:…`. Kinds: Person, Place, Faction, Object, Creature.
Include aliases for display names. polarity=assert, epistemic=world,
t_start="ch1". Every claim needs a short quote. Prefer **≤ 8** seed
claims (never more than 12). Do not invent UUID entity ids.

Predicate cheatsheet (illegal kinds → omit the claim):
- `status`: subject Person|Creature; object_lit only
  alive|dead|undead|missing; object_entity_id ""
- `located_in`: subject Person|Object|Creature; object Place
  (object_entity_id); object_lit ""
- `has`: subject Person|Creature|Place|Faction; object **Object only**
  (never Person/Place/Faction as the object of has)
- `knows`: subject Person; object any entity id; object_lit ""
- `allied_with` / `enemy_of`: subject+object Person|Faction; not both
  for the same pair
- `bound_to`: subject **Object**; object **Person**
  (never Person bound_to Object/Place)

Hard continuity:
- status=dead ⇒ **no** located_in for that subject (dead_not_located).
  Crime victims: status=dead only; crime scene is a Place entity.
- Living leads (detective etc.): status=alive + located_in a Place.
- Do not put status/located_in on Place or Faction subjects.
- Prefer sparse, schema-legal seeds over rich illegal ones.
- Unused claim object arms may be JSON null (Option); filled arms are
  non-null strings.

## outlines-prompt

Produce exactly N chapter outlines (chapter field 1..N in order). Each
outline: title, summary, beats (3–6 short strings), continuity_notes
(constraints the prose must obey given the bible). No claim rows here.

## extract

Extract only claims explicitly supported by the chapter text.
Same fiction.v1 cheatsheet as the bible: status / located_in / has /
knows / allied_with / enemy_of / bound_to with correct subject/object
kinds. Prefer known entity ids from the continuity pack. status
object_lit ∈ alive|dead|undead|missing. Unused object arm "".
polarity=assert, epistemic=world. Verbatim quote required. At most 12
claims. Dead subjects must not gain located_in. Do not treat beliefs as
world truth.

Functional preds: **at most one** `status`, `located_in`, and `bound_to`
per subject for this chapter time atom. If a character moves during the
chapter, emit only their **final** location.

Do **not** re-emit aliases for entities already in the pack (aliases are
bible-only). Only include `entities` rows for characters/places newly
introduced in this chapter; known ids need claims only.

For unused claim object arms use JSON null or omit (Option); never invent
fake ids. Filled arms must be non-null strings.

## body

```hwfl
type Finding = {
  finding_id: String,
  rule_id: String,
  severity: String,
  code: String,
  message: String,
  claim_ids: List<String>,
  event_ids: Option<List<String>>,
  entity_ids: Option<List<String>>,
  quotes: Option<List<String>>,
  repair_hint: Option<String>
}

type Applied = {
  entities: List<String>,
  aliases: List<String>,
  claims: List<String>,
  events: List<String>
}

type Rejected = {
  claims: List<String>,
  events: List<String>
}

type AssertResult = {
  ok: Bool,
  batch_id: String,
  mode: String,
  committed: Bool,
  findings: List<Finding>,
  applied: Applied,
  rejected: Rejected
}

type EntityUpsert = {
  entity_id: String,
  kind: String,
  name: String
}

type AliasUpsert = {
  alias: String,
  entity_id: String
}

type ClaimRow = {
  subject_id: String,
  pred: String,
  object_entity_id: String,
  object_lit: String,
  polarity: String,
  epistemic: String,
  t_start: String,
  quote: String
}

type LlmClaim = {
  subject_id: String,
  pred: String,
  object_entity_id: Option<String>,
  object_lit: Option<String>,
  polarity: String,
  epistemic: String,
  t_start: String,
  quote: String
}

type SourceRef = {
  kind: String,
  ref: String,
  attempt: Int
}

type AssertDelta = {
  entities: List<EntityUpsert>,
  aliases: List<AliasUpsert>,
  claims: List<ClaimRow>,
  source: SourceRef
}

type ExtractOut = {
  entities: List<EntityUpsert>,
  aliases: List<AliasUpsert>,
  claims: List<ClaimRow>
}

type LlmExtract = {
  entities: List<EntityUpsert>,
  aliases: List<AliasUpsert>,
  claims: List<LlmClaim>
}

type BibleOut = {
  title: String,
  synopsis: String,
  setting: String,
  entities: List<EntityUpsert>,
  aliases: List<AliasUpsert>,
  claims: List<ClaimRow>
}

type LlmBible = {
  title: String,
  synopsis: String,
  setting: String,
  entities: List<EntityUpsert>,
  aliases: List<AliasUpsert>,
  claims: List<LlmClaim>
}

type ChapterOutline = {
  chapter: Int,
  title: String,
  summary: String,
  beats: List<String>,
  continuity_notes: String
}

type OutlinesOut = {
  chapters: List<ChapterOutline>
}

type Out = {
  ok: Bool,
  project_id: String,
  title: String,
  chapters_requested: Int,
  chapters_committed: Int,
  contradiction_caught: Bool,
  findings_path: String,
  bible_path: String,
  outlines_path: String,
  snapshot_path: String,
  report: String
}

type ChapterState = {
  ok: Bool,
  committed: Int,
  caught: Bool,
  findings_path: String,
  last_prose: String,
  stop: Bool,
  gaps: List<Int>,
  outlines: List<ChapterOutline>
}

type BibleSeed = {
  assert: AssertResult,
  bible: BibleOut,
  regenerated: Bool
}

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

fun ensure_project(pid: String): String =
  let _ =
    try
      let _g = mcp.call(
        server = "kb",
        name = "kb_project_get",
        arguments = { project_id = pid }
      )
      let _r = mcp.call(
        server = "kb",
        name = "kb_project_reset",
        arguments = { project_id = pid, keep_ontology = true }
      )
      "reset"
    catch (_err) =>
      let _c = mcp.call(
        server = "kb",
        name = "kb_project_create",
        arguments = {
          id = pid,
          name = "Real story writer",
          ontology_pack = "fiction.v1"
        }
      )
      "created"
  pid

fun assert_delta(pid: String, mode: String, delta: AssertDelta): AssertResult =
  mcp.call(
    server = "kb",
    name = "kb_assert_delta",
    arguments = { project_id = pid, mode = mode, delta = delta },
    schema = schema(AssertResult)
  )

fun write_snapshot(pid: String, path: String): String =
  let snap = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  let _ = fs.write(path = path, text = json.encode(snap))
  path

fun pack_markdown(pid: String): String =
  let pack = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  json.encode(pack)

fun bible_delta(bible: BibleOut, attempt: Int): AssertDelta =
  {
    entities = bible.entities,
    aliases = bible.aliases,
    claims = take_claims(
      retarget_claims(bible.claims, "ch1", 0, list.length(bible.claims)),
      12,
      0
    ),
    source = { kind = "outline", ref = "bible", attempt = attempt }
  }

fun with_title(bible: BibleOut, title: String): BibleOut =
  {
    title = title,
    synopsis = bible.synopsis,
    setting = bible.setting,
    entities = bible.entities,
    aliases = bible.aliases,
    claims = bible.claims
  }

fun kind_of(ents: List<EntityUpsert>, id: String, i: Int, n: Int): String =
  if i >= n then ""
  else if ents[i].entity_id == id then ents[i].kind
  else kind_of(ents, id, i + 1, n)

fun status_lit_ok(s: String): Bool =
  s == "alive" || s == "dead" || s == "undead" || s == "missing"

fun is_person_or_creature(k: String): Bool =
  k == "Person" || k == "Creature"

fun is_person_or_faction(k: String): Bool =
  k == "Person" || k == "Faction"

fun claim_schema_ok(ents: List<EntityUpsert>, c: ClaimRow): Bool =
  let n = list.length(ents)
  let sk = kind_of(ents, c.subject_id, 0, n)
  if sk == "" then
    false
  else if c.pred == "status" then
    is_person_or_creature(sk)
      && c.object_entity_id == ""
      && status_lit_ok(c.object_lit)
  else if c.pred == "located_in" then
    (sk == "Person" || sk == "Object" || sk == "Creature")
      && c.object_lit == ""
      && kind_of(ents, c.object_entity_id, 0, n) == "Place"
  else if c.pred == "has" then
    (sk == "Person" || sk == "Creature" || sk == "Place" || sk == "Faction")
      && c.object_lit == ""
      && kind_of(ents, c.object_entity_id, 0, n) == "Object"
  else if c.pred == "knows" then
    sk == "Person"
      && c.object_lit == ""
      && kind_of(ents, c.object_entity_id, 0, n) != ""
  else if c.pred == "allied_with" || c.pred == "enemy_of" then
    is_person_or_faction(sk)
      && c.object_lit == ""
      && is_person_or_faction(kind_of(ents, c.object_entity_id, 0, n))
  else if c.pred == "bound_to" then
    sk == "Object"
      && c.object_lit == ""
      && kind_of(ents, c.object_entity_id, 0, n) == "Person"
  else
    false

fun subject_marked_dead(xs: List<ClaimRow>, sid: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if xs[i].subject_id == sid && xs[i].pred == "status" && xs[i].object_lit == "dead" then
    true
  else
    subject_marked_dead(xs, sid, i + 1, n)

fun claim_dead_loc_ok(xs: List<ClaimRow>, c: ClaimRow): Bool =
  if c.pred != "located_in" then true
  else not(subject_marked_dead(xs, c.subject_id, 0, list.length(xs)))

fun filter_schema_claims(
  ents: List<EntityUpsert>,
  xs: List<ClaimRow>,
  i: Int,
  n: Int
): List<ClaimRow> =
  if i >= n then []
  else if claim_schema_ok(ents, xs[i]) then
    list.concat([xs[i]], filter_schema_claims(ents, xs, i + 1, n))
  else
    filter_schema_claims(ents, xs, i + 1, n)

fun filter_dead_loc_claims(xs: List<ClaimRow>, i: Int, n: Int): List<ClaimRow> =
  if i >= n then []
  else if claim_dead_loc_ok(xs, xs[i]) then
    list.concat([xs[i]], filter_dead_loc_claims(xs, i + 1, n))
  else
    filter_dead_loc_claims(xs, i + 1, n)

fun sanitize_bible(bible: BibleOut): BibleOut =
  let schema_ok =
    filter_schema_claims(bible.entities, bible.claims, 0, list.length(bible.claims))
  let cleaned = filter_dead_loc_claims(schema_ok, 0, list.length(schema_ok))
  {
    title = bible.title,
    synopsis = bible.synopsis,
    setting = bible.setting,
    entities = bible.entities,
    aliases = bible.aliases,
    claims = take_claims(cleaned, 12, 0)
  }

fun first_kind_id(ents: List<EntityUpsert>, kind: String, i: Int, n: Int): String =
  if i >= n then ""
  else if ents[i].kind == kind then ents[i].entity_id
  else first_kind_id(ents, kind, i + 1, n)

fun minimal_person_claims(
  ents: List<EntityUpsert>,
  place: String,
  i: Int,
  n: Int
): List<ClaimRow> =
  if i >= n then []
  else if ents[i].kind != "Person" then
    minimal_person_claims(ents, place, i + 1, n)
  else
    let sid = ents[i].entity_id
    let status_row = {
      subject_id = sid,
      pred = "status",
      object_entity_id = "",
      object_lit = "alive",
      polarity = "assert",
      epistemic = "world",
      t_start = "ch1",
      quote = $"{ents[i].name} lived."
    }
    let rest = minimal_person_claims(ents, place, i + 1, n)
    if place == "" then
      list.concat([status_row], rest)
    else
      let loc_row = {
        subject_id = sid,
        pred = "located_in",
        object_entity_id = place,
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = $"{ents[i].name} was there."
      }
      list.concat([status_row, loc_row], rest)

fun minimal_safe_bible(bible: BibleOut): BibleOut =
  let ents = bible.entities
  let n = list.length(ents)
  let place = first_kind_id(ents, "Place", 0, n)
  {
    title = bible.title,
    synopsis = bible.synopsis,
    setting = bible.setting,
    entities = ents,
    aliases = bible.aliases,
    claims = take_claims(minimal_person_claims(ents, place, 0, n), 12, 0)
  }

fun regen_bible(
  model: String,
  premise: String,
  title_hint: String,
  chapters: Int,
  prev: BibleOut,
  findings_json: String
): BibleOut =
  let raw = llm.object(
    prompt = $"{@bible-prompt}\n\nDesired title hint: {title_hint}\nChapter count target: {chapters}\n\nPremise:\n{premise}\n\nPrevious bible (JSON):\n{json.encode(prev)}\n\nAssert dry_run findings (must disappear):\n{findings_json}\n\nRegenerate the full bible so these findings are gone. Keep the premise. Emit ≤8 schema-legal claims only. Unused object arms may be null. Fix KIND_MISMATCH and dead+located_in. Prefer living detective alive+located_in; dead victim status=dead with no located_in.",
    schema = schema(LlmBible),
    model = model
  )
  from_llm_bible(raw)

fun try_bible_dry(pid: String, bible: BibleOut, attempt: Int): BibleSeed =
  let clean = sanitize_bible(bible)
  let dry = assert_delta(pid, "dry_run", bible_delta(clean, attempt))
  { assert = dry, bible = clean, regenerated = false }

fun commit_clean_bible(pid: String, seed: BibleSeed, regenerated: Bool): BibleSeed =
  {
    assert = assert_delta(pid, "commit", bible_delta(seed.bible, 99)),
    bible = seed.bible,
    regenerated = regenerated
  }

fun commit_or_repair_bible(
  pid: String,
  model: String,
  premise: String,
  title_hint: String,
  chapters: Int,
  bible: BibleOut
): BibleSeed =
  let t1 = try_bible_dry(pid, bible, 1)
  if t1.assert.ok then
    commit_clean_bible(pid, t1, false)
  else
    let _ = fs.write(path = "story/bible-findings.json", text = json.encode(t1.assert))
    if model == "" then
      { assert = t1.assert, bible = t1.bible, regenerated = false }
    else
      let f1 = json.encode(t1.assert.findings)
      let r1 = with_title(
        regen_bible(model, premise, title_hint, chapters, t1.bible, f1),
        bible.title
      )
      let _ = write_bible_md(r1, "story/bible-regen.md")
      let _ = write_bible_md(r1, "story/bible.md")
      let t2 = try_bible_dry(pid, r1, 2)
      let _ = fs.write(path = "story/bible-findings.json", text = json.encode(t2.assert))
      if t2.assert.ok then
        commit_clean_bible(pid, t2, true)
      else
        let f2 = json.encode(t2.assert.findings)
        let r2 = with_title(
          regen_bible(model, premise, title_hint, chapters, t2.bible, f2),
          bible.title
        )
        let _ = write_bible_md(r2, "story/bible-regen2.md")
        let _ = write_bible_md(r2, "story/bible.md")
        let t3 = try_bible_dry(pid, r2, 3)
        let _ = fs.write(path = "story/bible-findings.json", text = json.encode(t3.assert))
        if t3.assert.ok then
          commit_clean_bible(pid, t3, true)
        else
          let mini = minimal_safe_bible(r2)
          let _ = write_bible_md(mini, "story/bible-minimal.md")
          let _ = write_bible_md(mini, "story/bible.md")
          let t4 = try_bible_dry(pid, mini, 4)
          let _ = fs.write(path = "story/bible-findings.json", text = json.encode(t4.assert))
          if t4.assert.ok then
            commit_clean_bible(pid, t4, true)
          else
            { assert = t4.assert, bible = t4.bible, regenerated = true }

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

fun opt_str(o: Option<String>): String =
  match o with
  | None => ""
  | Some(s) => s

fun normalize_llm_claim(c: LlmClaim, t: String): ClaimRow =
  {
    subject_id = c.subject_id,
    pred = c.pred,
    object_entity_id = opt_str(c.object_entity_id),
    object_lit = opt_str(c.object_lit),
    polarity = c.polarity,
    epistemic = c.epistemic,
    t_start = t,
    quote = c.quote
  }

fun normalize_llm_claims(xs: List<LlmClaim>, t: String, i: Int, n: Int): List<ClaimRow> =
  if i >= n then []
  else list.concat([normalize_llm_claim(xs[i], t)], normalize_llm_claims(xs, t, i + 1, n))

fun from_llm_extract(raw: LlmExtract, t_atom: String): ExtractOut =
  sanitize_extract({
    entities = raw.entities,
    aliases = raw.aliases,
    claims = normalize_llm_claims(raw.claims, t_atom, 0, list.length(raw.claims))
  })

fun from_llm_bible(raw: LlmBible): BibleOut =
  {
    title = raw.title,
    synopsis = raw.synopsis,
    setting = raw.setting,
    entities = raw.entities,
    aliases = raw.aliases,
    claims = normalize_llm_claims(raw.claims, "ch1", 0, list.length(raw.claims))
  }

fun extract_claims(model: String, chapter: String, t_atom: String, pack: String): ExtractOut =
  let raw = llm.object(
    prompt = $"{@extract}\n\nChapter time atom (set every claim t_start to this): {t_atom}\n\nContinuity pack (JSON):\n{pack}\n\nChapter:\n{chapter}",
    schema = schema(LlmExtract),
    model = model
  )
  from_llm_extract(raw, t_atom)

fun repair_extract(
  model: String,
  chapter: String,
  t_atom: String,
  pack: String,
  prev: ExtractOut,
  findings_json: String
): ExtractOut =
  let raw = llm.object(
    prompt = $"{@extract}\n\nChapter time atom: {t_atom}\n\nContinuity pack (JSON):\n{pack}\n\nPrevious extract (JSON):\n{json.encode(prev)}\n\nAssert findings (must disappear — fix the claim rows, prefer fewer claims):\n{findings_json}\n\nChapter:\n{chapter}\n\nReturn a corrected extract only. Unused object arms may be null. Do not invent bilocation. One located_in/status/bound_to per subject.",
    schema = schema(LlmExtract),
    model = model
  )
  from_llm_extract(raw, t_atom)

fun extract_to_delta(ex: ExtractOut, ref: String, attempt: Int): AssertDelta =
  {
    entities = ex.entities,
    aliases = ex.aliases,
    claims = ex.claims,
    source = { kind = "chapter", ref = ref, attempt = attempt }
  }

fun is_functional_pred(p: String): Bool =
  p == "status" || p == "located_in" || p == "bound_to"

fun earlier_func_claim(
  xs: List<ClaimRow>,
  sid: String,
  pred: String,
  i: Int,
  end: Int
): Bool =
  if i >= end then false
  else if xs[i].subject_id == sid && xs[i].pred == pred then true
  else earlier_func_claim(xs, sid, pred, i + 1, end)

fun filter_functional_dups(xs: List<ClaimRow>, i: Int, n: Int): List<ClaimRow> =
  if i >= n then []
  else
    let c = xs[i]
    let rest = filter_functional_dups(xs, i + 1, n)
    if is_functional_pred(c.pred) && earlier_func_claim(xs, c.subject_id, c.pred, 0, i) then
      rest
    else
      list.concat([c], rest)

fun claim_schema_soft(ents: List<EntityUpsert>, c: ClaimRow): Bool =
  let sk = kind_of(ents, c.subject_id, 0, list.length(ents))
  if sk == "" then
    if c.pred == "status" then
      c.object_entity_id == "" && status_lit_ok(c.object_lit)
    else if c.pred == "located_in" || c.pred == "has" || c.pred == "knows" || c.pred == "allied_with" || c.pred == "enemy_of" || c.pred == "bound_to" then
      c.object_lit == "" && c.object_entity_id != ""
    else
      false
  else
    claim_schema_ok(ents, c)

fun filter_schema_soft(
  ents: List<EntityUpsert>,
  xs: List<ClaimRow>,
  i: Int,
  n: Int
): List<ClaimRow> =
  if i >= n then []
  else if claim_schema_soft(ents, xs[i]) then
    list.concat([xs[i]], filter_schema_soft(ents, xs, i + 1, n))
  else
    filter_schema_soft(ents, xs, i + 1, n)

fun claim_refs_entity(c: ClaimRow, id: String): Bool =
  c.subject_id == id || c.object_entity_id == id

fun entity_used_in_claims(claims: List<ClaimRow>, id: String, i: Int, n: Int): Bool =
  if i >= n then false
  else if claim_refs_entity(claims[i], id) then true
  else entity_used_in_claims(claims, id, i + 1, n)

fun filter_used_entities(
  ents: List<EntityUpsert>,
  claims: List<ClaimRow>,
  i: Int,
  n: Int
): List<EntityUpsert> =
  if i >= n then []
  else if entity_used_in_claims(claims, ents[i].entity_id, 0, list.length(claims)) then
    list.concat([ents[i]], filter_used_entities(ents, claims, i + 1, n))
  else
    filter_used_entities(ents, claims, i + 1, n)

fun sanitize_extract(ex: ExtractOut): ExtractOut =
  let schema_ok =
    filter_schema_soft(ex.entities, ex.claims, 0, list.length(ex.claims))
  let dead_ok = filter_dead_loc_claims(schema_ok, 0, list.length(schema_ok))
  let deduped = filter_functional_dups(dead_ok, 0, list.length(dead_ok))
  let claims = take_claims(deduped, 12, 0)
  {
    entities = filter_used_entities(ex.entities, claims, 0, list.length(ex.entities)),
    aliases = empty_aliases(()),
    claims = claims
  }

fun host_assert_fail(msg: String): AssertResult =
  {
    ok = false,
    batch_id = $"host-err:{msg}",
    mode = "dry_run",
    committed = false,
    findings = empty_findings(()),
    applied = {
      entities = empty_strings(()),
      aliases = empty_strings(()),
      claims = empty_strings(()),
      events = empty_strings(())
    },
    rejected = {
      claims = empty_strings(()),
      events = empty_strings(())
    }
  }

fun try_commit_extract(
  pid: String,
  ex: ExtractOut,
  ref: String,
  attempt: Int
): AssertResult =
  let delta = extract_to_delta(ex, ref, attempt)
  try
    let dry = assert_delta(pid, "dry_run", delta)
    if dry.ok then
      try
        assert_delta(pid, "commit", delta)
      catch (_err) =>
        host_assert_fail("commit failed")
    else
      dry
  catch (_err) =>
    host_assert_fail("dry_run failed")

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
  let beats = join_lines(outline.beats, 0, list.length(outline.beats))
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
fun resolve_premise(mode: String, premise: String): String =
  if mode != "live" then premise
  else if premise != "" then premise
  else
    human.ask({
      prompt = "Premise>",
      detail = "Describe the story you want (genre, tone, length hint, must-haves)."
    })

fun smoke_bible(): BibleOut =
  {
    title = "Ashport Compass",
    synopsis = "Mira arrives in Ashport with a salt-stained compass and must decide whether to trust the harbor master.",
    setting = "Ashport, a fogbound harbor town",
    entities = [
      { entity_id = "char:mira", kind = "Person", name = "Mira" },
      { entity_id = "char:harbor_master", kind = "Person", name = "Harbor Master Kell" },
      { entity_id = "place:ashport", kind = "Place", name = "Ashport" },
      { entity_id = "obj:compass", kind = "Object", name = "Salt Compass" }
    ],
    aliases = [
      { alias = "Mira", entity_id = "char:mira" },
      { alias = "Kell", entity_id = "char:harbor_master" },
      { alias = "Harbor Master", entity_id = "char:harbor_master" },
      { alias = "Ashport", entity_id = "place:ashport" },
      { alias = "Salt Compass", entity_id = "obj:compass" }
    ],
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira lived."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira stood on the Ashport quay."
      },
      {
        subject_id = "char:mira",
        pred = "has",
        object_entity_id = "obj:compass",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira kept the Salt Compass in her coat."
      },
      {
        subject_id = "obj:compass",
        pred = "bound_to",
        object_entity_id = "char:mira",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "The Salt Compass answered only to Mira."
      },
      {
        subject_id = "char:harbor_master",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Harbor Master Kell lived."
      },
      {
        subject_id = "char:harbor_master",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Kell kept office in Ashport."
      }
    ]
  }

fun smoke_outlines(): OutlinesOut =
  {
    chapters = [
      {
        chapter = 1,
        title = "Quay Fog",
        summary = "Mira arrives and meets Kell.",
        beats = ["Dock in fog", "Show the compass", "Kell warns her"],
        continuity_notes = "Mira alive at Ashport; she has the Salt Compass."
      },
      {
        chapter = 2,
        title = "Ledger Room",
        summary = "Kell tests whether Mira will surrender the compass.",
        beats = ["Argument in the ledger room", "Mira refuses", "She keeps watch"],
        continuity_notes = "Do not kill Mira; she remains in Ashport."
      },
      {
        chapter = 3,
        title = "North Pier",
        summary = "Mira and Kell form a wary alliance at the north pier.",
        beats = ["Shared watch", "Alliance", "Compass still hers"],
        continuity_notes = "Mira alive; allied_with Kell; still has compass."
      }
    ]
  }

fun smoke_ch1_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "knows",
        object_entity_id = "char:harbor_master",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Mira learned Harbor Master Kell's name."
      }
    ],
    source = { kind = "chapter", ref = "ch1", attempt = 1 }
  }

fun smoke_ch2_bad_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "dead",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira died on the ledger-room floor."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Dead Mira still paced Ashport's ledger room."
      }
    ],
    source = { kind = "chapter", ref = "ch2", attempt = 1 }
  }

fun smoke_ch2_good_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira lived through the argument."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira remained in Ashport's ledger room."
      },
      {
        subject_id = "char:mira",
        pred = "has",
        object_entity_id = "obj:compass",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Mira kept the Salt Compass."
      }
    ],
    source = { kind = "chapter", ref = "ch2", attempt = 2 }
  }

fun smoke_ch3_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:mira",
        pred = "allied_with",
        object_entity_id = "char:harbor_master",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "Mira and Kell stood allied on the north pier."
      },
      {
        subject_id = "char:mira",
        pred = "located_in",
        object_entity_id = "place:ashport",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "They kept watch over Ashport from the north pier."
      },
      {
        subject_id = "char:mira",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch3",
        quote = "Mira lived."
      }
    ],
    source = { kind = "chapter", ref = "ch3", attempt = 1 }
  }

fun write_bible_md(bible: BibleOut, path: String): String =
  let text =
    $"# {bible.title}\n\n## Synopsis\n\n{bible.synopsis}\n\n## Setting\n\n{bible.setting}\n\n## Entities\n\n{json.encode(bible.entities)}\n\n## Aliases\n\n{json.encode(bible.aliases)}\n\n## Seed claims\n\n{json.encode(bible.claims)}\n"
  let _ = fs.write(path = path, text = text)
  path

fun run_smoke(pid: String): Out =
  let _ = ensure_project(pid)
  let _ = fs.mkdir("story")
  let _ = fs.mkdir("outlines")
  let bible = smoke_bible()
  let bible_path = write_bible_md(bible, "story/bible.md")
  let seed = commit_or_repair_bible(pid, "", "", "", 3, bible)
  let outlines = smoke_outlines()
  let outlines_path = "outlines/chapters.md"
  let _ = fs.write(
    path = outlines_path,
    text = format_outlines(outlines.chapters, 0, list.length(outlines.chapters))
  )
  let ch1_prose =
    "Fog pressed Ashport's quay into a narrow strip of wet boards. Mira stepped off the packet boat with the Salt Compass hard against her ribs. Harbor Master Kell met her with a lantern and a ledger under his arm. He said her name like a debt. She answered that the compass was hers, and that she intended to keep breathing in this town."
  let _ = fs.write(path = "story/ch1.md", text = ch1_prose)
  let c1 = assert_delta(pid, "commit", smoke_ch1_delta())
  let snap1 = write_snapshot(pid, "story/canon-after-ch1.md")
  let bad = assert_delta(pid, "dry_run", smoke_ch2_bad_delta())
  let findings_path = "story/ch2-findings.json"
  let _ = fs.write(path = findings_path, text = json.encode(bad))
  let ch2_bad_prose =
    "ERROR PATH: planted dead+located clash for Mira (not committed)."
  let _ = fs.write(path = "story/ch2-attempt1.md", text = ch2_bad_prose)
  let ch2_prose =
    "In the ledger room Kell asked for the Salt Compass as harbor bond. Mira refused without raising her voice. She lived through the argument, stayed in Ashport, and kept the compass buttoned in her coat while the fog tapped the windows."
  let _ = fs.write(path = "story/ch2.md", text = ch2_prose)
  let c2 =
    if bad.ok then
      {
        ok = false,
        committed = false,
        note = "planted contradiction was not caught"
      }
    else
      let good = assert_delta(pid, "commit", smoke_ch2_good_delta())
      {
        ok = good.ok && good.committed,
        committed = good.committed,
        note = "regen committed"
      }
  let ch3_prose =
    "By the north pier Mira and Kell shared a watch. They stood allied against the unlit water. Mira lived. Ashport held them both, and the Salt Compass still answered her hand."
  let _ = fs.write(path = "story/ch3.md", text = ch3_prose)
  let c3 = assert_delta(pid, "commit", smoke_ch3_delta())
  let snap_path = write_snapshot(pid, "story/canon.md")
  let caught = not(bad.ok)
  let committed_n =
    (if c1.ok && c1.committed then 1 else 0)
      + (if c2.committed then 1 else 0)
      + (if c3.ok && c3.committed then 1 else 0)
  let ok =
    seed.assert.ok
      && seed.assert.committed
      && c1.ok
      && c1.committed
      && c2.ok
      && c3.ok
      && c3.committed
      && caught
  let findings_json = json.encode(bad.findings)
  let report =
    if ok then
      $"smoke ok: contradiction caught ({findings_json}); committed {committed_n} chapters; snap1={snap1}"
    else
      $"smoke failed: seed.ok={seed.assert.ok} c1.ok={c1.ok} c2.ok={c2.ok} c3.ok={c3.ok} caught={caught} note={c2.note}"
  {
    ok = ok,
    project_id = pid,
    title = bible.title,
    chapters_requested = 3,
    chapters_committed = committed_n,
    contradiction_caught = caught,
    findings_path = findings_path,
    bible_path = bible_path,
    outlines_path = outlines_path,
    snapshot_path = snap_path,
    report = report
  }

fun write_one_chapter(
  pid: String,
  model: String,
  i: Int,
  st: ChapterState
): ChapterState =
  let t = chapter_atom(i)
  let pack = pack_markdown(pid)
  let outline = outline_at(st.outlines, i, 0, list.length(st.outlines))
  let beats = join_lines(outline.beats, 0, list.length(outline.beats))
  let prompt =
    $"Continuity pack (JSON):\n{pack}\n\nChapter {i} title: {outline.title}\nSummary: {outline.summary}\nBeats:\n{beats}\nContinuity notes:\n{outline.continuity_notes}\n\nPrior chapter (tail/context):\n{st.last_prose}\n\nWrite chapter {i} now."
  let draft = llm.chat(system = @system, prompt = prompt, model = model)
  let path = chapter_path(i)
  let _ = fs.write(path = path, text = draft)
  let findings_path = $"story/{t}-findings.json"
  let ex1 = extract_claims(model, draft, t, pack)
  let r1 = try_commit_extract(pid, ex1, t, 1)
  let _ = fs.write(path = findings_path, text = json.encode(r1))
  if r1.ok && r1.committed then
    let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
    finish_chapter(st, draft, findings_path, true, false, i, st.outlines)
  else
    let f1 = json.encode(r1.findings)
    let ex2 = repair_extract(model, draft, t, pack, ex1, f1)
    let r2 = try_commit_extract(pid, ex2, t, 2)
    let _ = fs.write(path = findings_path, text = json.encode(r2))
    if r2.ok && r2.committed then
      let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
      finish_chapter(st, draft, findings_path, true, true, i, st.outlines)
    else
      let f2 = json.encode(r2.findings)
      let prose2 = rewrite_chapter_prose(model, pack, outline, i, st.last_prose, f2, draft)
      let _ = fs.write(path = $"story/{t}-regen.md", text = prose2)
      let _ = fs.write(path = path, text = prose2)
      let ex3 = extract_claims(model, prose2, t, pack)
      let r3 = try_commit_extract(pid, ex3, t, 3)
      let _ = fs.write(path = findings_path, text = json.encode(r3))
      if r3.ok && r3.committed then
        let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
        finish_chapter(st, prose2, findings_path, true, true, i, st.outlines)
      else
        let f3 = json.encode(r3.findings)
        let prose3 = rewrite_chapter_prose(model, pack, outline, i, st.last_prose, f3, prose2)
        let _ = fs.write(path = $"story/{t}-regen2.md", text = prose3)
        let _ = fs.write(path = path, text = prose3)
        let ex4 = extract_claims(model, prose3, t, pack)
        let r4 = try_commit_extract(pid, ex4, t, 4)
        let _ = fs.write(path = findings_path, text = json.encode(r4))
        if r4.ok && r4.committed then
          let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
          finish_chapter(st, prose3, findings_path, true, true, i, st.outlines)
        else
          let f4 = json.encode(r4.findings)
          let o2 = regen_one_outline(model, outline, f4, pack)
          let outlines2 = replace_outline(st.outlines, i - 1, o2, 0, list.length(st.outlines))
          let _ = fs.write(
            path = "outlines/chapters.md",
            text = format_outlines(outlines2, 0, list.length(outlines2))
          )
          let prose4 = rewrite_chapter_prose(model, pack, o2, i, st.last_prose, f4, prose3)
          let _ = fs.write(path = $"story/{t}-regen-outline.md", text = prose4)
          let _ = fs.write(path = path, text = prose4)
          let ex5 = extract_claims(model, prose4, t, pack)
          let r5 = try_commit_extract(pid, ex5, t, 5)
          let _ = fs.write(path = findings_path, text = json.encode(r5))
          if r5.ok && r5.committed then
            let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
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
  let t = chapter_atom(chapter_i)
  let path = chapter_path(chapter_i)
  let prose = fs.read(path).text
  let pack = pack_markdown(pid)
  let findings_path = $"story/{t}-pass2-findings.json"
  let ex1 = extract_claims(model, prose, t, pack)
  let r1 = try_commit_extract(pid, ex1, $"pass2-{t}", 1)
  let _ = fs.write(path = findings_path, text = json.encode(r1))
  if r1.ok && r1.committed then
    let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
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
    let ex2 = repair_extract(model, prose, t, pack, ex1, f1)
    let r2 = try_commit_extract(pid, ex2, $"pass2-{t}", 2)
    let _ = fs.write(path = findings_path, text = json.encode(r2))
    if r2.ok && r2.committed then
      let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
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
      let outline = outline_at(st.outlines, chapter_i, 0, list.length(st.outlines))
      let f2 = json.encode(r2.findings)
      let prose2 = rewrite_chapter_prose(model, pack, outline, chapter_i, st.last_prose, f2, prose)
      let _ = fs.write(path = $"story/{t}-pass2-regen.md", text = prose2)
      let _ = fs.write(path = path, text = prose2)
      let ex3 = extract_claims(model, prose2, t, pack)
      let r3 = try_commit_extract(pid, ex3, $"pass2-{t}", 3)
      let _ = fs.write(path = findings_path, text = json.encode(r3))
      if r3.ok && r3.committed then
        let _ = write_snapshot(pid, $"story/canon-after-{t}.md")
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

fun run_live(
  pid: String,
  model: String,
  premise: String,
  chapters: Int,
  title_in: String,
  strict_kb: Bool
): Out =
  let n = normalize_chapters(chapters)
  let _ = ensure_project(pid)
  let _ = fs.mkdir("story")
  let _ = fs.mkdir("outlines")
  let title_hint =
    if title_in == "" then "(invent a fitting title)" else title_in
  let bible0 = from_llm_bible(
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
  let bible = with_title(bible0, story_title)
  let bible_path = write_bible_md(bible, "story/bible.md")
  let seed = commit_or_repair_bible(pid, model, premise, title_hint, n, bible)
  if not(seed.assert.ok) || not(seed.assert.committed) then
    let snap_path = write_snapshot(pid, "story/canon.md")
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
      text = format_outlines(outlines.chapters, 0, list.length(outlines.chapters))
    )
    let st0 = {
      ok = true,
      committed = 0,
      caught = false,
      findings_path = "",
      last_prose = "(no prior chapter)",
      stop = false,
      gaps = empty_ints(()),
      outlines = outlines.chapters
    }
    let st1 = write_chapters(pid, model, 1, n, st0)
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
          gaps = empty_ints(()),
          outlines = st1.outlines
        }
        pass2_gaps(pid, model, gaps1, 0, list.length(gaps1), cleared)
    let _ = fs.write(path = "story/kb-gaps.json", text = json.encode(st2.gaps))
    let snap_path = write_snapshot(pid, "story/canon.md")
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
    run_smoke(pid)
```
