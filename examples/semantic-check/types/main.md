---
name: types/main
effects: []
---

## body

```hwfl
type Finding = {
  severity: String,
  category: String,
  file: String,
  claim: String,
  evidence: String,
  suggestion: String
}

type CheckRow = {
  ok: Bool,
  error: String,
  name: String,
  path: String
}

type Slice = {
  id: String,
  file: String,
  title: String,
  body: String,
  entropy: Float,
  uniqueness: Float
}

type GateItem = {
  slice_id: String,
  file: String,
  body: String,
  gate_source: String,
  review_task: String,
  peer_file: String,
  peer_body: String,
  context: String,
  priority: Int
}

type Contradiction = {
  quote_a: String,
  quote_b: String,
  why: String
}

type ObligationExtract = {
  actor: String,
  modality: String,
  action: String,
  object: String,
  condition: String,
  quote: String
}

type OblRow = {
  actor: String,
  modality: String,
  action: String,
  object: String,
  condition: String,
  quote: String,
  file: String
}

type RoleMismatch = {
  quote: String,
  why: String
}

type RoleRow = {
  role: String,
  file: String,
  slice_id: String
}

type PropExtract = {
  form: String,
  atom: String,
  condition: String,
  quote: String
}

type PropRow = {
  form: String,
  atom: String,
  condition: String,
  quote: String,
  file: String
}

type SkillExecHint = {
  id: String,
  file: String,
  quote: String
}

type ReviewPack = {
  findings: List<Finding>,
  obligations: List<OblRow>,
  propositions: List<PropRow>,
  roles: List<RoleRow>
}

type PragmaticOut = {
  illocutionary_force: String,
  felicity_violations: List<String>,
  contradictions: List<Contradiction>,
  clarity_score: Float,
  obligations: List<ObligationExtract>,
  propositions: List<PropExtract>,
  role: String,
  mismatched_sentences: List<RoleMismatch>
}
```
