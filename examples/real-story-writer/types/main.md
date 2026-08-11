---
name: types/main
effects: []
---

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
```
