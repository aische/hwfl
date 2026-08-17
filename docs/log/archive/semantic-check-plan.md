# Semantic-check — research plan (“semantic type system”)

**Archived 2026-08-17.** Shipped layers live in
[`examples/semantic-check/`](../../../examples/semantic-check/). S4 / S6
remain parked ([TASKS.md](../../TASKS.md)).

**Status:** **parked research.** **S2** (obligation graph), **S1** (role
typing), **S5** (prose↔code contracts), and **S3** (proposition algebra)
shipped. S4 / S6 not on the critical path — resume when a lab or
coding-agent gap needs a new judgment. Optional later use: static
**fitness filter** before burning tokens on a candidate run. Ship
increments inside `examples/semantic-check/` (same-run layers; policy in
workflow; no semantic host-op fan-out).

**Related:** [idea.md](idea.md) goal 10 (dogfood semantic analysis),
`examples/semantic-check/`, [spec/12-example-suite.md](spec/12-example-suite.md)
E20, log entries 2026-07-17 (deepen / noise fix / A+B / S2 / S1 / S5 / S3).

## 1. Stance (metaphor, not claim)

Working metaphor: a **semantic type system** for agent modules — prose and
prompts as meaning-bearing surfaces that admit **checkable judgments**,
analogous to how classical types attach judgments to terms.

This is **not** a claim that natural language has Γ ⊢ e : τ. It is a
research stance:

> Can we attach checkable judgments to meaning-bearing text the way types
> attach checkable judgments to terms — and program those judgments in
> hwfl (`meaning → meaning`)?

| Classical type system | Semantic analogue (here) |
| --------------------- | ------------------------ |
| Syntax → AST | Module → slices / roles / claims |
| Typing rules | Review tasks + `llm.object` schemas |
| Γ | Catalog, skills, entry, prior findings (later: run spans) |
| Progress / preservation | Agent can act without self-contradiction / dead refs |
| Soundness | Conservative findings with **quoted evidence** |

**Healthy metaphor test:** every new check must answer what a failed
judgment would **block or repair**. Essayistic “clarity” without a role,
obligation, or interface contract is criticism, not a judgment.

**Anti-pattern:** treat the LLM as an oracle that “proves” coherence.
**Pattern (already shipped):** deterministic cheap filters → small gated
meaning judgments → structured evidence.

## 2. Shipped surface (proto-judgments)

Implemented in `examples/semantic-check/workflows/main.md`:

| Layer | Judgment (roughly) | Notes |
| ----- | ------------------ | ----- |
| 0 | Structural well-formedness | `meta.check_module` |
| 1 | Prose name resolution | qnames ↔ catalog (`text.is_qname`, …) |
| 2 | Corpus anomaly | entropy vs local mean — **routing signal**, not “duplication” |
| 2 | Within-slice redundancy | similarity > 0.9, quoted pair evidence, cap 16 (**B**) |
| 2b | Speech-act heuristic | agent/system sections should contain directives |
| 3 | Policy conflict | skills / system / rules → `check_internal_conflict` (**A**); quoted `quote_a` / `quote_b` / `why` |
| 3b | Obligation graph | extract `{actor, modality, action, object, condition?, quote}` on gated reviews; deterministic must∧must_not / system must vs skill may / catalog-missing object (**S2**) |
| 3c | Proposition algebra | `must`/`must_not`/`prefer`/`prefer_not` (+ condition); Must∧MustNot and Must vs Prefer(~a); conditional discharge (**S3**) |
| 3a | Illocutionary role | forced `role` + quoted `mismatched_sentences`; Policy/System need directives; Example must not smuggle hard constraints (**S1**) |
| 2c | Prose↔code contract | dead bindable `@section`; prose host-op vs `effects`/`tools`; schema field vs `outputs:`; skill `exec.run` vs caller effects (**S5**) |
| — | Gate discipline | body-bearing `review_gate`; unique by `(slice_id, review_task)`; policy first; cap 10; H1-only skills get synthetic `{path}/skill` slices |

Scan scope: `workflows/` / `skills/` / `lib/` / `types/` only.

## 3. Three strata (where this is going)

1. **Syntax / structure** — modules, qnames, effects (mostly done).
2. **Normative interface** — roles, obligations, cross-slice consistency
   (A+B is the start).
3. **Dynamics** — does a run obey the loaded meaning? (spans / resume;
   slightly different product surface, same judgment style).

Speech-act theory → vocabulary for (2). Information theory → **attention /
gating**, not the judgment itself. Propositional mapping → only if the
claim language is **tiny and schema-enforced**.

## 4. Candidate experiments (later)

Promote one at a time into semantic-check (or a sibling module). Keep
caps, quotes, and same-run layer 3 unless a milestone explicitly splits
packaging.

### Phase S1 — Illocutionary role typing — **shipped**

Assign each gated section a forced role and check felicity.

Roles: `System` | `Policy` | `Procedure` | `Example` |
`Rationale` | `ToolDoc`.

Checks:

- `Policy` / `System` must contain directives (must / should / never)
- `Example` must not introduce hard constraints unless marked normative /
  illustrative
- Role mismatch: LLM quotes sentences that break the assigned role

Schema-forced LLM output (`role`, `mismatched_sentences[]` with `quote` /
`why`). Deterministic felicity on the assigned role (no extra gate slots).
Report: `roles` + `pragmatic_findings` with `category: role`. Fixture:
`example-hard-rule`.

### Phase S2 — Obligation graph — **shipped**

Cross-module consistency beats within-slice conflict for real agents.

Extract normative claims into a controlled schema on every gated
`llm.object` (field `PragmaticOut.obligations`):

```text
{ actor, modality: must|should|may|must_not, action, object, condition?, quote }
```

Deterministic graph checks on the extracted set (no extra gate slots):

- same `(actor, action, object)` with `must` and `must_not` (unconditioned
  or same condition; finding cap 4)
- workflows `must` vs skills `may`/`should` (soft / info; cap 4; skipped
  when graph row count > 8)
- obligation `object` qname missing from the catalog (tie to layer 1; cap 4)

Caps to stay under pure crunch: extract only on
`check_internal_conflict` gates; ≤4 obligations per slice (LLM may
propose ≤8); graph sees at most 12 rows. Pair scans early-exit on finding
budget (single recursion, no full-triangle walk after saturation). Pure
crunch host limit raised to 500k for chatty extracts.

Report: `obligations` + `pragmatic_findings` with `category: obligation`.
Fixtures: `require-search` / `forbid-search` / `ghost-tool`. Still gated
`llm.object` + quotes; no open-world NLI.

### Phase S3 — Narrow propositional projection — **shipped**

Only for normative sentences already selected by speech-act / policy /
obligation gates. Emit a small algebra:

`Must(a)` | `MustNot(a)` | `If(c, Must(a))` | `Prefer(a)` | `Prefer(~a)`

(`prefer_not` = Prefer(~a); non-empty `condition` = If(c, …).)

Check only obvious clashes (`Must(a) ∧ MustNot(a)`, unconditioned
`Must` vs `Prefer(~a)`). Preserve conditional discharge (situation A vs B
both OK) — same rule as today’s conflict reviewer.

Implementation: `PragmaticOut.propositions` on policy gates + deterministic
projection from stamped obligations; merge/dedupe; ≤4/slice, ≤12 graph
rows; finding caps 4; `category: proposition`; report lists `propositions`.
Fixture: `prefer-no-search` (with require/forbid for Must∧MustNot). Gate
cap raised 8→10 so planted policy fixtures stay gated. Avoid full FOL /
open entailment.

### Phase S4 — Info-theoretic routing (not findings)

Keep entropy as gate features; avoid “duplicated” wording.

Useful variants:

- Directive density (directives / sentences): underspecified vs brittle
- Skill near-clone (high similarity, different tags) → “skill clone” gate
- Surprise vs catalog: instructs “use the stack skill” but never names
  discoverable skills

### Phase S5 — Prose ↔ code interface contracts — **shipped**

hwfl-specific leverage: bind section claims to frontmatter / effects /
tools. Deterministic layer 2c (no extra LLM / gate slots):

- Bindable sections (`system` / `agent` / `reviewer` / `prompt` / `user` /
  `instructions`) with body never referenced as `@slug` in a module that
  has an `hwfl` fence
- Prose names `exec.run` / `fs.write` / `llm.*` (etc.) but frontmatter
  `effects:` lacks the matching capability (callable modules only)
- When `tools =` is present, prose host-op names without matching
  `tool(...)` form
- `## schema …` bullet fields absent from typed `outputs:` lines
- Skill recommends `exec.run` and a workflow without `Exec` names that
  skill qname

Findings `category: contract` (cap 16). Fixtures: `ok` dead `@agent`,
`exec-gap`, `output-gap`, `skill-exec-gap` + `recommend-exec`. Coding-agent
deterministic dogfood stays contract-clean.

### Phase S6 — Trace-conditioned (dynamic) semantics

Γ includes the run:

- Did the agent violate a loaded skill’s `must_not`?
- Was `skill.load` required before first write and skipped?
- `ok=true` after non-zero verify?

Same judgment style (quoted obligation + span evidence). May live as a
separate workflow over `.hwfl/runs` rather than static module scan.

## 5. Deprioritize

- Global sentence×sentence NLI (expensive, noisy)
- Open “is this clear?” without role / obligation / contract
- Embedding-only topic drift without a norm
- New host builtins for semantic analysis (policy stays in-language)
- Split `semantic-pragmatic` / JSON reload packaging until strata 2–3
  need it (same-run layer 3 is enough now)

## 6. Design locks (carry forward)

1. Same-run optional pragmatic; gate before LLM; empty gate ⇒ no calls.
2. Findings need evidence quotes when claiming conflict / felicity.
3. Caps on pairs / gate size; scan module trees only.
4. Entropy ≠ redundancy; don’t describe outliers as “duplicated.”
5. Prefer workflow `fun`s + tiny pure `text.*`; no semantic-check micro-tools.
6. Avoid reserved hwfl keywords in author code (`task`, …).

## 7. Acceptance heuristics (when promoting a phase)

- Fixture or dogfood shows a **repairable** false-friend (planted conflict,
  role mismatch, cross-module must/must_not).
- Coding-agent deterministic mode stays low-noise (`ok:true` absent
  planted issues).
- Pragmatic mode only spends tokens on gated slices.
- Report schema stays stable enough for tests (`findings` /
  `pragmatic_findings` / `review_gate`).

## 8. Suggested order when resumed

1. ~~**S2 obligation graph**~~ **done**
2. ~~**S1 role typing**~~ **done**
3. ~~**S5 prose↔code contracts**~~ **done**
4. ~~**S3 proposition algebra**~~ **done**
5. **S4** as gate features (info-theoretic routing)
6. **S6** when run-store / span APIs make dynamic checks cheap
