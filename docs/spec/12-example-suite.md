# 12 — Example suite (design oracle)

These programs define the language more sharply than prose. During
implementation, each gets: expected type, expected host-span sequence
(pattern), and snapshot points.

Syntax may drift; **contracts** should not.

Legend: **P** = pure, **H** = host, **R** = resume-sensitive, **C** = confirm,
**A** = agent.

---

## E01 — Hello pure **P**

```hwfl
fun main(_): { msg: String } =
  { msg = "hello" }
```

Spans: module only. Snapshots: entry/return optional.

## E02 — Let / match **P**

```hwfl
fun pick(xs: List<Int>): Int =
  match xs with
  | [] => 0
  | [x] => x
  | [x, y] => x + y
  | _ => -1
```

Need `+` in prelude (pure builtin or stdlib).

## E03 — Section prompt bind **H**

Module with `## system` and `llm.chat(system = @system, …)`.

Snapshots: `fs?` none; one `llm.chat`; return.

## E04 — Summarise file **H** **R**

Classic read + llm + write report path. Resume killed mid-llm: one
duplicate call max.

## E05 — Interpolation / FileRef **P/H**

Ensure `FileRef` interpolates as path; `Bytes` rejected at check.

## E06 — Option / Result **P**

Decode optional fields without null feet-guns.

## E07 — `par` map **H** **R**

```hwfl
par(max = 4) for p in paths {
  fs.read(p)
}
```

Ordered results; resume mid-pool restores slots.

## E08 — `par` + confirm **C** **R**

Branch calls `exec.run` → confirm freezes pool. `hwfl approve --yes`
continues.

## E09 — `join` two tasks **H**

Independent llm+fs joined.

## E10 — `try` / catch provider error **H**

Force provider failure; catch; return fallback string.

## E11 — Same-project nested entry call **H** **R** **check**

`workflows/main` imports `workflows/inner` and calls
`workflows/inner(inputs)`. Same run / workspace; typed outputs; `FrInvoke`
nest (not `meta.invoke`).

Acceptance:

- [ ] `main` imports + calls `workflows/inner`; outputs flow back typed
- [ ] Snapshot / spans show nested `module:workflows/inner` under the
      caller; `FrInvoke` + nested machine in snapshot
- [ ] Mid-inner `--step` or `confirm` pause bubbles; resume continues outer
- [ ] Caller missing a callee effect → **check** fail (no silent `Meta`)
- [ ] (Optional) `tool(wrap)` where `wrap` calls `workflows/inner`

## E12 — Effect rejected **check**

Module declares `effects: [Read]` but calls `llm.chat` ⇒ `hwfl check` fails.

## E13 — Exec allowlist **check/runtime**

`exec.run("rm", …)` not in allowlist ⇒ check or runtime policy error.

## E14 — `llm.object` + schema **H**

```hwfl
type Out = { summary: String, score: Int }
llm.object(..., schema = schema(Out), model = …) : Out
```

**Shipped:** check infers `Out` when `schema = schema(Out)`; runtime host op +
mock/simple providers via `chatResponseFormat`. Fixture:
`test/Hwfl/Runtime/ObjectSpec.hs`.

## E15 — Agent with tools **A** **R**

Agent may call `fs.read` and a user `fun search`. Step granularity =
model/tool rounds.

## E15b — Typed agent + submit **A** **R**

```hwfl
type Out = { summary: String, score: Int }
llm.agent_object(..., schema = schema(Out), tools = [...], …)
  : { value: Out, rounds: Int }
```

Model gathers with tools then must call synthetic `submit` alone. Fixture:
`test/Hwfl/Runtime/AgentObjectSpec.hs`; example `examples/agent-object.md`.

## E16 — `obs.span` region **H**

User span wraps a thunk; result type is the body type (not forced to Unit).
Children host ops nest under the region span. Fixture in
`test/Hwfl/Obs/SpanSpec.hs`; example `examples/obs-span.md`.

Surface (either form):

```text
obs.span("cluster")(fun () => e)   -- curried
obs.span("cluster", fun () => e)   -- two-arg / named name+body
```

## E17 — Secret redaction **H**

`Secret<String>` never appears in `show` / spans cleartext.

## E18 — Stale project resume **R**

Change module source; resume refuses with exit code 4.

Lone-module runs pin `projectHashOf`; project runs pin
`projectHashForModules`. Resume walks from `rmEntry` for `project.json`
and recomputes the matching hash (skills from project root when found).
Covered by ConcurrentSpec (lone + project confirm/approve + project
stale).

## E19 — Lib-only list helpers **P**

`lib/list.unique_by` written in hwfl replaces hwfi `builtin/list-unique-by`.

## E20 — Mini semantic gate **H**

**Shipped (M8 + deepen + S2 + S1 + S5 + S3):** `examples/semantic-check/workflows/main.md` —
layers 0–2c deterministic review (structural, prose refs, corpus, speech-act
hints, prose↔code contracts) + body-bearing `review_gate` (max 10). Optional
same-run layer 3 (`mode=pragmatic`) via `llm.object` on gated slices →
`pragmatic_findings`; obligation extraction + deterministic graph
(must∧must_not, soft system/skill, catalog-missing objects); proposition
algebra (Must∧MustNot, Must vs Prefer(~a)); illocutionary role typing
(`role` + mismatched sentences; Policy/Example felicity). One module; uses
`meta.check_module`, `fs.find`, pure `list` / `text` / `md` prelude helpers.
Fixture: `test/fixtures/semantic-target`.

## E21 — Universal coding agent **A** **H**

**Shipped:** `examples/coding-agent` — credible skill-driven shape: chat
(`human.ask`) → `coding_session` / `gather_context` tools (`FrInvoke`) →
typed plan → serial do_task / `workflows/verify`. Planner and coder use
`skill.*`; verifier is non-agent. Flat one-shot agent kept as
`examples/simple-coding-agent`. Fixture: `test/Hwfl/Runtime/CodingAgentSpec.hs`
(plus `SimpleCodingAgentSpec`).

## E22 — Local compare / genetic lab **H**

**Shipped:** `examples/compare` — parent materializes N candidate projects
+ per-trial workspaces from seeded `genomes/` + `fixture/`, then
`meta.check_project` / `meta.invoke` / `meta.read_spans`, ranks by
feasibility then fewer `llm.*` spans. **Mutate loop:** `fs.patch` turns
`rich` → `stripped` (drop draft `llm.chat`), then re-runs elite + mutant
(generation 1). Fixture: `CompareSpec` (mock; winner = lean;
`trial_count` = 4, `generations` = 2).

## E23 — Evolve coding-agent genomes **H**

**Shipped:** `examples/evolve-agent` — lab parent scores slim coding-agent
genomes (`wasteful` vs `tight`) on a **seeded broken** Python fixture
(`stats.py` / `test_stats.py`) via nested `meta.invoke`. Fitness = task
`ok` then fewer `llm.*` spans. Mutation uses an operator menu
(`strip_warmup` / `shrink_rounds` / `drop_fs_list`): `llm.object` patch
with **no-op rejection**, then gen-rotated structural fallbacks. Isolated
`trials/g{N}/{id}/`. Fixture: `EvolveAgentSpec` (mock; winner = `tight`;
3 gens → 6 trials; `mut-g0` ≠ `mut-g1`).


---

## Contracts table (summary)

| Id      | Check       | Run | Resume   | Spans                 |
| ------- | ----------- | --- | -------- | --------------------- |
| E01     | ✓           | ✓   | —        | module                |
| E03–E04 | ✓           | ✓   | mid-llm  | fs?/llm/fs?           |
| E07–E08 | ✓           | ✓   | mid-par  | par + children        |
| E12–E13 | fail closed | —   | —        | —                     |
| E14     | ✓           | ✓   | —        | llm.object            |
| E15     | ✓           | ✓   | mid-tool | agent tree            |
| E15b    | ✓           | ✓   | mid-tool | agent_object + submit |
| E16     | ✓           | ✓   | —        | region `obs.span`     |
| E20     | ✓           | ✓   | optional | library spans         |
| E21     | ✓           | ✓   | mid-tool | agent_object + exec   |
| E22     | ✓           | ✓   | —        | nested invoke + spans |
| E23     | ✓           | ✓   | —        | evolve agent genomes  |

## Using the suite

1. Add fixtures under `examples/` / `test/fixtures/` in the greenfield repo.
2. Wire golden tests per milestone (don’t require LLM for pure/check cases).
3. For LLM cases, use a mock `LlmProvider`.
