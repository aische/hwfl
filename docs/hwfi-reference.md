# hwfi reference

Keep the **hwfi** repository adjacent to the new project as a reference.
Copy code only when the behaviour is still desired and the new design does
not contradict it.

## Reuse aggressively (ideas / tests / algorithms)

| Area | hwfi locus (approx.) | Why |
|------|----------------------|-----|
| Frame / cursor resume | `docs/execution-model.md`, `Hwfi.Runtime.Machine*` | Transition model is the right durability unit |
| `par` + confirm freeze | execution-model § par | Cooperative global freeze avoids workspace races |
| Workspace sandbox | `Hwfi.Runtime.Workspace` | Symlink containment, path prefix checks |
| Secret redaction | spec §8 / value redaction | Traces must not leak keys |
| Model catalog | `model-catalog.json` + gateways | Config shape can migrate behind `LlmProvider` |
| `exec` allowlist | `project.json` `exec` policy | Opt-in process spawn |
| Trace event kinds | RunStart / Step* / Llm* | Starting point for events; spans supersede flat `ctx.trace` for UX |
| Agent tool loop states | `MachineAgent`, agent `Current` | Reify as frames/current in new machine |
| Project load / check pipeline | Parse → Check → Run | Keep fail-closed `check` |
| Merkle / project hash staleness | refuse resume on project change | Same policy |

## Do **not** copy as-is

| Area | Why |
|------|-----|
| Step DSL (`binder <- qname(…)`) | Too weak as a GP language |
| Expression sub-language (`Expr` without let/fun/match) | Forced micro-tools |
| One-file-per-helper pattern in `examples/semantic-check/tools` | Symptom to eliminate |
| Content-addressed step cache (pre-M6) | Already abandoned; don’t resurrect |
| Growing `builtin/list-*` / `builtin/json-*` in Haskell | Belongs in pml stdlib |
| Dual language forever (`step` + script) | Migration aid only, not end state |

## When asking an agent to copy from hwfi

Be explicit:

1. Quote the *behaviour* or invariant needed (e.g. “confirm freezes par pool”).
2. Point at hwfi files for reference.
3. Require the new implementation to sit behind pml’s host-op / frame APIs.
4. Reject ports that reintroduce a second computation DSL.

## Semantic-check dogfood

hwfi’s `examples/semantic-check` is the regression oracle for **author
ergonomics**. The pml port lives at `examples/semantic-check/` (M8): **1**
module vs hwfi’s **74** tools — see [examples/semantic-check/README.md](../examples/semantic-check/README.md).
Use that delta as a design fitness score ([spec/10-acceptance.md](spec/10-acceptance.md)).
