---
name: lib/extract
effects: [Net]
imports:
  - types/main
  - lib/util
  - lib/claims
---

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

fun from_llm_extract(raw: LlmExtract, t_atom: String): ExtractOut =
  lib/claims.sanitize_extract({
    entities = raw.entities,
    aliases = raw.aliases,
    claims = normalize_llm_claims(raw.claims, t_atom, 0, list.length(raw.claims))
  })

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
```
