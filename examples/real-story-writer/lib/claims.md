---
name: lib/claims
effects: []
imports:
  - types/main
  - lib/util
---

## body

```hwfl
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
    claims = lib/util.take_claims(cleaned, 12, 0)
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
    claims = lib/util.take_claims(minimal_person_claims(ents, place, 0, n), 12, 0)
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
  let claims = lib/util.take_claims(deduped, 12, 0)
  {
    entities = filter_used_entities(ex.entities, claims, 0, list.length(ex.entities)),
    aliases = lib/util.empty_aliases(()),
    claims = claims
  }
```
