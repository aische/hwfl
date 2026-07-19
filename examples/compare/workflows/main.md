---
name: workflows/main
inputs: {}
outputs:
  winner: String
  trial_count: Int
  results_path: String
effects: [Read, Write, Meta]
---

# Compare lab

Materialize candidate projects from genomes/ and fixture into candidates/
and trials/, then check, invoke, and rank by fewer llm spans.

## body

```hwfl
type Trial = {
  id: String,
  check_ok: Bool,
  run_ok: Bool,
  status: String,
  run_id: String,
  span_count: Int,
  llm_spans: Int,
  feasible: Bool,
  outcome_json: String,
  error: String
}

fun materialize(id: String): {} =
  let _ = fs.copy(src = $"genomes/{id}", dst = $"candidates/{id}", overwrite = true)
  let article = fs.read("fixture/article.txt")
  let _ = fs.write(path = $"trials/{id}/article.txt", text = article.text)
  {}

fun run_trial(id: String): Trial =
  let _ = materialize(id)
  let chk = meta.check_project($"candidates/{id}")
  if not(chk.ok) then
    {
      id = id,
      check_ok = false,
      run_ok = false,
      status = "check_failed",
      run_id = "",
      span_count = 0,
      llm_spans = 0,
      feasible = false,
      outcome_json = "null",
      error = chk.error
    }
  else
    let inv = meta.invoke(
      project = $"candidates/{id}",
      workspace = $"trials/{id}",
      inputs = { path = "article.txt" }
    )
    let spans = meta.read_spans(
      run_id = inv.run_id,
      workspace = $"trials/{id}"
    )
    let llm = meta.read_spans(
      run_id = inv.run_id,
      workspace = $"trials/{id}",
      name_prefix = "llm."
    )
    let span_n = if spans.ok then list.length(spans.spans) else 0
    let llm_n = if llm.ok then list.length(llm.spans) else 0
    let feasible = chk.ok && inv.ok && inv.status == "completed"
    {
      id = id,
      check_ok = chk.ok,
      run_ok = inv.ok,
      status = inv.status,
      run_id = inv.run_id,
      span_count = span_n,
      llm_spans = llm_n,
      feasible = feasible,
      outcome_json = json.encode(inv.outcome),
      error = inv.error
    }

fun run_all(ids: List<String>, i: Int, n: Int): List<Trial> =
  if i >= n then []
  else list.concat([run_trial(ids[i])], run_all(ids, i + 1, n))

fun better(a: Trial, b: Trial): Trial =
  if not(a.feasible) then b
  else if not(b.feasible) then a
  else if a.llm_spans < b.llm_spans then a
  else if b.llm_spans < a.llm_spans then b
  else if a.span_count < b.span_count then a
  else if b.span_count < a.span_count then b
  else a

fun pick_best(trials: List<Trial>, i: Int, n: Int, best: Trial): Trial =
  if i >= n then best
  else pick_best(trials, i + 1, n, better(best, trials[i]))

fun main(_): { winner: String, trial_count: Int, results_path: String } =
  let ids = ["lean", "rich"]
  let trials = run_all(ids, 0, list.length(ids))
  let n = list.length(trials)
  let empty = {
    id = "",
    check_ok = false,
    run_ok = false,
    status = "",
    run_id = "",
    span_count = 0,
    llm_spans = 0,
    feasible = false,
    outcome_json = "null",
    error = "no trials"
  }
  let best =
    if n == 0 then empty
    else pick_best(trials, 1, n, trials[0])
  let winner = if best.feasible then best.id else ""
  let report = {
    winner = winner,
    trials = trials
  }
  let _ = fs.write(path = "results.json", text = json.encode(report))
  { winner = winner, trial_count = n, results_path = "results.json" }
```
