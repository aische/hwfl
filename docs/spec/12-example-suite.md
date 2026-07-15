# 12 — Example suite (design oracle)

These programs define the language more sharply than prose. During
implementation, each gets: expected type, expected host-span sequence
(pattern), and snapshot points.

Syntax may drift; **contracts** should not.

Legend: **P** = pure, **H** = host, **R** = resume-sensitive, **C** = confirm,
**A** = agent.

---

## E01 — Hello pure **P**

```pml
fun main(_): { msg: String } =
  { msg = "hello" }
```

Spans: module only. Snapshots: entry/return optional.

## E02 — Let / match **P**

```pml
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

```pml
par(max = 4) for p in paths {
  fs.read(p)
}
```

Ordered results; resume mid-pool restores slots.

## E08 — `par` + confirm **C** **R**

Branch calls `exec.run` → confirm freezes pool. `pml approve --yes`
continues.

## E09 — `join` two tasks **H**

Independent llm+fs joined.

## E10 — `try` / catch provider error **H**

Force provider failure; catch; return fallback string.

## E11 — Nested module invoke **H** **R**

`workflows/main` calls `workflows/inner`. Nested frames in snapshot.

## E12 — Effect rejected **check**

Module declares `effects: [Read]` but calls `llm.chat` ⇒ `pml check` fails.

## E13 — Exec allowlist **check/runtime**

`exec.run("rm", …)` not in allowlist ⇒ check or runtime policy error.

## E14 — `llm.object` + schema **H**

```pml
type Out = { summary: String, score: Int }
llm.object(..., schema = schema(Out), model = …) : Out
```

## E15 — Agent with tools **A** **R**

Agent may call `fs.read` and a user `fun search`. Step granularity =
model/tool rounds.

## E16 — `obs.span` region **H**

User span wraps pure clustering; children host ops nest correctly.

## E17 — Secret redaction **H**

`Secret<String>` never appears in `show` / spans cleartext.

## E18 — Stale project resume **R**

Change module source; resume refuses with exit code 4.

## E19 — Lib-only list helpers **P**

`lib/list.unique_by` written in pml replaces hwfi `builtin/list-unique-by`.

## E20 — Mini semantic gate **H**

Single project approximating hwfi review-gate: map/filter/unique in-language,
optional one llm call. File budget: ≤ 5 modules.

---

## Contracts table (summary)

| Id | Check | Run | Resume | Spans |
|----|-------|-----|--------|-------|
| E01 | ✓ | ✓ | — | module |
| E03–E04 | ✓ | ✓ | mid-llm | fs?/llm/fs? |
| E07–E08 | ✓ | ✓ | mid-par | par + children |
| E12–E13 | fail closed | — | — | — |
| E15 | ✓ | ✓ | mid-tool | agent tree |
| E20 | ✓ | ✓ | optional | library spans |

## Using the suite

1. Add fixtures under `examples/` / `test/fixtures/` in the greenfield repo.
2. Wire golden tests per milestone (don’t require LLM for pure/check cases).
3. For LLM cases, use a mock `LlmProvider`.
