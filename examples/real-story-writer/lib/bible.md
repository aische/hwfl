---
name: lib/bible
effects: [Net, Write, Exec, Read]
imports:
  - types/main
  - lib/kb
  - lib/claims
  - lib/util
---

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

## body

```hwfl
fun bible_delta(bible: BibleOut, attempt: Int): AssertDelta =
  {
    entities = bible.entities,
    aliases = bible.aliases,
    claims = lib/util.take_claims(
      lib/util.retarget_claims(bible.claims, "ch1", 0, list.length(bible.claims)),
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

fun write_bible_md(bible: BibleOut, path: String): String =
  let text =
    $"# {bible.title}\n\n## Synopsis\n\n{bible.synopsis}\n\n## Setting\n\n{bible.setting}\n\n## Entities\n\n{json.encode(bible.entities)}\n\n## Aliases\n\n{json.encode(bible.aliases)}\n\n## Seed claims\n\n{json.encode(bible.claims)}\n"
  let _ = fs.write(path = path, text = text)
  path

fun normalize_llm_claim(c: LlmClaim, t: String): ClaimRow =
  {
    subject_id = c.subject_id,
    pred = c.pred,
    object_entity_id = lib/util.opt_str(c.object_entity_id),
    object_lit = lib/util.opt_str(c.object_lit),
    polarity = c.polarity,
    epistemic = c.epistemic,
    t_start = t,
    quote = c.quote
  }

fun normalize_llm_claims(xs: List<LlmClaim>, t: String, i: Int, n: Int): List<ClaimRow> =
  if i >= n then []
  else list.concat([normalize_llm_claim(xs[i], t)], normalize_llm_claims(xs, t, i + 1, n))

fun from_llm_bible(raw: LlmBible): BibleOut =
  {
    title = raw.title,
    synopsis = raw.synopsis,
    setting = raw.setting,
    entities = raw.entities,
    aliases = raw.aliases,
    claims = normalize_llm_claims(raw.claims, "ch1", 0, list.length(raw.claims))
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
  let clean = lib/claims.sanitize_bible(bible)
  let dry = lib/kb.assert_delta(pid, "dry_run", bible_delta(clean, attempt))
  { assert = dry, bible = clean, regenerated = false }

fun commit_clean_bible(pid: String, seed: BibleSeed, regenerated: Bool): BibleSeed =
  {
    assert = lib/kb.assert_delta(pid, "commit", bible_delta(seed.bible, 99)),
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
          let mini = lib/claims.minimal_safe_bible(r2)
          let _ = write_bible_md(mini, "story/bible-minimal.md")
          let _ = write_bible_md(mini, "story/bible.md")
          let t4 = try_bible_dry(pid, mini, 4)
          let _ = fs.write(path = "story/bible-findings.json", text = json.encode(t4.assert))
          if t4.assert.ok then
            commit_clean_bible(pid, t4, true)
          else
            { assert = t4.assert, bible = t4.bible, regenerated = true }
```
