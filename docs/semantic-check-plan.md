# Semantic-check — research plan (“semantic type system”)

**Status:** exploratory backlog. Not scheduled in [TASKS.md](TASKS.md)
Now. Ship increments inside `examples/semantic-check/` (same-run layers;
policy in workflow; no semantic host-op fan-out).

**Related:** [idea.md](idea.md) goal 8 (dogfood semantic analysis),
`examples/semantic-check/`, [spec/12-example-suite.md](spec/12-example-suite.md)
E20, log entries 2026-07-17 (deepen / noise fix / A+B).

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
| — | Gate discipline | body-bearing `review_gate`; unique by `(slice_id, review_task)`; policy first; cap 8; H1-only skills get synthetic `{path}/skill` slices |

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

### Phase S1 — Illocutionary role typing

Assign each gated section a forced role and check felicity.

Suggested roles: `System` | `Policy` | `Procedure` | `Example` |
`Rationale` | `ToolDoc`.

Checks (examples):

- `Policy` must contain directives (must / should / never), not only vibes
- `Example` must not introduce hard constraints unless marked normative
- `Procedure` steps mostly imperatives / ordered
- Role mismatch: policy-shaped bullet inside an example → felicity warning

Schema-forced LLM output (`role`, `mismatched_sentences[]` with quotes).
Closest thing to a **type** for prose sections: role ≈ kind; felicity ≈
intro/elim rules.

### Phase S2 — Obligation graph (preferred next after A+B)

Cross-module consistency beats within-slice conflict for real agents.

Extract normative claims into a controlled schema, e.g.:

```text
{ actor, modality: must|should|may|must_not, action, object, condition? }
```

Deterministic graph checks on the extracted set:

- same `(actor, action, object)` with `must` and `must_not`
- system `must` vs skill `may` / “prefer otherwise” (soft conflict)
- obligation names a tool/skill missing from the catalog (tie to layer 1)

Generalizes GHC2021 vs Haskell2010 from “two sentences in one skill” to
the agent’s **instruction lattice**. Still gated `llm.object` + quotes;
no open-world NLI.

### Phase S3 — Narrow propositional projection

Only for normative sentences already selected by speech-act / policy /
obligation gates. Emit a small algebra, e.g.:

`Must(a)` | `MustNot(a)` | `If(c, Must(a))` | `Prefer(a)`

Check only obvious clashes (`Must(a) ∧ MustNot(a)`, unconditioned
`Must` vs `Prefer(¬a)`). Preserve conditional discharge (situation A vs B
both OK) — same rule as today’s conflict reviewer.

Avoid full FOL / open entailment.

### Phase S4 — Info-theoretic routing (not findings)

Keep entropy as gate features; avoid “duplicated” wording.

Useful variants:

- Directive density (directives / sentences): underspecified vs brittle
- Skill near-clone (high similarity, different tags) → “skill clone” gate
- Surprise vs catalog: instructs “use the stack skill” but never names
  discoverable skills

### Phase S5 — Prose ↔ code interface contracts

hwfl-specific leverage: bind section claims to frontmatter / effects /
tools.

Examples:

- `## system` names tools not allowed by `effects` / tool lists
- skill recommends `exec` verify but caller lacks `Exec`
- `@section` never interpolated (dead prose)
- prose promises output fields absent from `outputs:`

Classical types check the fence; this checks **prose as another interface
surface** next to YAML.

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

1. **S2 obligation graph** (highest leverage on coding-agent-class modules)
2. **S1 role typing** (sharpens speech-act layer already present)
3. **S5 prose↔code contracts** (unique to hwfl modules)
4. **S3** only if S2’s claim schema is stable
5. **S4** as gate features while doing the above
6. **S6** when run-store / span APIs make dynamic checks cheap
