---
name: workflows/main
inputs:
    mode: String
    model: String
    project_id: String
outputs:
    ok: Bool
    project_id: String
    contradiction_caught: Bool
    committed: Bool
    findings_path: String
    snapshot_path: String
    chapter_path: String
    report: String
effects: [Read, Write, Net, Exec]
examples:
    - name: fixture
      inputs:
          mode: fixture
          model: deepseek4flash
          project_id: story-demo
---

## overview

Story continuity dogfood against an external **kb-mcp** stdio server
(`fiction.v1` ontology).

- `mode=fixture` — no LLM required for the continuity proof: seed canon,
  dry-run a planted dead+located clash, then commit a clean chapter delta.
- `mode=live` — write a short chapter with `llm.chat`, extract claims with
  `llm.object`, dry-run / one regen / commit via `kb_assert_delta`.

KB state lives in the workspace SQLite file (default `.kb/story.sqlite`).
Prose artifacts land under `story/`.

## system

You write quiet fantasy prose. Obey the continuity pack and any finding
list exactly. No preamble, no bullet lists, no meta commentary.

## extract

Extract only claims that are explicitly supported by the chapter text.
Use closed fiction.v1 predicates: located_in, status, has, knows,
allied_with, enemy_of, bound_to. Entity ids look like `char:elara`,
`place:harbor`. status object_lit is one of alive|dead|undead|missing.
For entity-valued objects fill object_entity_id and leave object_lit "".
For literals fill object_lit and leave object_entity_id "". Always include
a verbatim quote. Prefer a short list over guessing.

## chapter_prompt

Write a short chapter (3-5 paragraphs) continuing this story.

Continuity constraints (must obey):
- Elara (char:elara) is a Person; status=alive at ch1.
- Elara is located_in Harbor (place:harbor) at ch1.
- Do not kill Elara or place a dead character in a location.

Tone: quiet fantasy, no preamble, no bullet lists.

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

type Out = {
  ok: Bool,
  project_id: String,
  contradiction_caught: Bool,
  committed: Bool,
  findings_path: String,
  snapshot_path: String,
  chapter_path: String,
  report: String
}

fun empty_entities(_: Unit): List<EntityUpsert> = []
fun empty_aliases(_: Unit): List<AliasUpsert> = []

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
          name = "Story writer demo",
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

fun seed_delta(): AssertDelta =
  {
    entities = [
      { entity_id = "char:elara", kind = "Person", name = "Elara" },
      { entity_id = "place:harbor", kind = "Place", name = "Harbor" }
    ],
    aliases = [
      { alias = "Elara", entity_id = "char:elara" },
      { alias = "Harbor", entity_id = "place:harbor" }
    ],
    claims = [
      {
        subject_id = "char:elara",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Elara lived."
      },
      {
        subject_id = "char:elara",
        pred = "located_in",
        object_entity_id = "place:harbor",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch1",
        quote = "Elara stood at the Harbor."
      }
    ],
    source = { kind = "outline", ref = "bible", attempt = 1 }
  }

fun bad_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:elara",
        pred = "status",
        object_entity_id = "",
        object_lit = "dead",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Elara died in the storm."
      },
      {
        subject_id = "char:elara",
        pred = "located_in",
        object_entity_id = "place:harbor",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Dead Elara walked the Harbor docks."
      }
    ],
    source = { kind = "chapter", ref = "ch2-bad", attempt = 1 }
  }

fun good_delta(): AssertDelta =
  {
    entities = empty_entities(()),
    aliases = empty_aliases(()),
    claims = [
      {
        subject_id = "char:elara",
        pred = "status",
        object_entity_id = "",
        object_lit = "alive",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Elara lived through the storm."
      },
      {
        subject_id = "char:elara",
        pred = "located_in",
        object_entity_id = "place:harbor",
        object_lit = "",
        polarity = "assert",
        epistemic = "world",
        t_start = "ch2",
        quote = "Elara kept watch over the Harbor."
      }
    ],
    source = { kind = "chapter", ref = "ch2", attempt = 1 }
  }

fun write_snapshot(pid: String, path: String): String =
  let snap = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  let text = json.encode(snap)
  let _ = fs.write(path = path, text = text)
  path

fun run_fixture(pid: String): Out =
  let _ = ensure_project(pid)
  let seed = assert_delta(pid, "commit", seed_delta())
  let bad = assert_delta(pid, "dry_run", bad_delta())
  let findings_path = "story/ch2-bad-findings.json"
  let _ = fs.mkdir("story")
  let _ = fs.write(path = findings_path, text = json.encode(bad))
  let ch_path = "story/ch2.md"
  let chapter =
    if bad.ok then
      "ERROR: planted contradiction was not caught."
    else
      "Elara lived through the storm. She kept watch over the Harbor while the tide dragged wreckage past the pilings."
  let _ = fs.write(path = ch_path, text = chapter)
  let good = assert_delta(pid, "commit", good_delta())
  let snap_path = write_snapshot(pid, "story/canon.md")
  let caught = not(bad.ok)
  let ok = seed.ok && caught && good.ok && good.committed
  let findings_json = json.encode(bad.findings)
  let report =
    if ok then
      $"fixture ok: contradiction caught ({findings_json}) then committed ch2"
    else
      $"fixture failed: seed.ok={seed.ok} caught={caught} good.ok={good.ok} committed={good.committed}"
  {
    ok = ok,
    project_id = pid,
    contradiction_caught = caught,
    committed = good.committed,
    findings_path = findings_path,
    snapshot_path = snap_path,
    chapter_path = ch_path,
    report = report
  }

fun pack_markdown(pid: String): String =
  let pack = mcp.call(
    server = "kb",
    name = "kb_snapshot",
    arguments = { project_id = pid, format = "markdown" }
  )
  json.encode(pack)

fun extract_claims(model: String, chapter: String, t_atom: String): ExtractOut =
  llm.object(
    prompt = $"{@extract}\n\nChapter time atom: {t_atom}\n\nChapter:\n{chapter}",
    schema = schema(ExtractOut),
    model = model
  )

fun extract_to_delta(ex: ExtractOut, ref: String, attempt: Int): AssertDelta =
  {
    entities = ex.entities,
    aliases = ex.aliases,
    claims = ex.claims,
    source = { kind = "chapter", ref = ref, attempt = attempt }
  }

fun run_live(pid: String, model: String): Out =
  let _ = ensure_project(pid)
  let seed = assert_delta(pid, "commit", seed_delta())
  let _ = fs.mkdir("story")
  let pack = pack_markdown(pid)
  let draft = llm.chat(
    system = @system,
    prompt = $"Continuity pack (JSON):\n{pack}\n\n{@chapter_prompt}",
    model = model
  )
  let ch_path = "story/ch1-live.md"
  let _ = fs.write(path = ch_path, text = draft)
  let ex1 = extract_claims(model, draft, "ch1")
  let dry1 = assert_delta(pid, "dry_run", extract_to_delta(ex1, "ch1-live", 1))
  let findings_path = "story/ch1-live-findings.json"
  let _ = fs.write(path = findings_path, text = json.encode(dry1))
  let final =
    if dry1.ok then
      {
        prose = draft,
        assert = assert_delta(pid, "commit", extract_to_delta(ex1, "ch1-live", 1)),
        caught = false
      }
    else
      let findings_json = json.encode(dry1.findings)
      let repaired = llm.chat(
        system = @system,
        prompt = $"Continuity pack:\n{pack}\n\nFindings from assert dry_run:\n{findings_json}\n\nRewrite the chapter so these findings disappear. Keep it short.\n\nPrevious chapter:\n{draft}",
        model = model
      )
      let _ = fs.write(path = "story/ch1-live-regen.md", text = repaired)
      let ex2 = extract_claims(model, repaired, "ch1")
      let dry2 = assert_delta(pid, "dry_run", extract_to_delta(ex2, "ch1-live", 2))
      let _ = fs.write(path = findings_path, text = json.encode(dry2))
      if dry2.ok then
        {
          prose = repaired,
          assert = assert_delta(pid, "commit", extract_to_delta(ex2, "ch1-live", 2)),
          caught = true
        }
      else
        { prose = repaired, assert = dry2, caught = true }
  let snap_path = write_snapshot(pid, "story/canon.md")
  let ok = seed.ok && final.assert.ok && final.assert.committed
  let findings_json = json.encode(final.assert.findings)
  let report =
    if ok then
      $"live ok: committed={final.assert.committed} regen={final.caught}"
    else
      $"live failed: seed.ok={seed.ok} assert.ok={final.assert.ok} findings={findings_json}"
  {
    ok = ok,
    project_id = pid,
    contradiction_caught = final.caught,
    committed = final.assert.committed,
    findings_path = findings_path,
    snapshot_path = snap_path,
    chapter_path = ch_path,
    report = report
  }

fun main(inputs): Out =
  let pid =
    if inputs.project_id == "" then "story-demo" else inputs.project_id
  if inputs.mode == "live" then
    run_live(pid, inputs.model)
  else
    run_fixture(pid)
```
