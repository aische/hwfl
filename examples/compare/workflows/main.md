---
name: workflows/main
inputs: {}
outputs:
  winner: String
  trial_count: Int
  generations: Int
  results_path: String
effects: [Read, Write, Meta]
---

# Compare lab

Materialize candidate projects from genomes/ and fixture into candidates/
and trials/, score by fewer llm spans, mutate the costlier genome, then
re-run an elite + mutant generation.

## body

```hwfl
type Trial = {
  gen: Int,
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

fun empty_trial(err: String): Trial =
  {
    gen = 0,
    id = "",
    check_ok = false,
    run_ok = false,
    status = "",
    run_id = "",
    span_count = 0,
    llm_spans = 0,
    feasible = false,
    outcome_json = "null",
    error = err
  }

fun materialize(id: String): {} =
  let _ = fs.copy(src = $"genomes/{id}", dst = $"candidates/{id}", overwrite = true)
  let article = fs.read("fixture/article.txt")
  let _ = fs.write(path = $"trials/{id}/article.txt", text = article.text)
  {}

fun run_trial(gen: Int, id: String): Trial =
  let _ = materialize(id)
  let chk = meta.check_project($"candidates/{id}")
  if not(chk.ok) then
    {
      gen = gen,
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
      gen = gen,
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

fun run_all(gen: Int, ids: List<String>, i: Int, n: Int): List<Trial> =
  if i >= n then []
  else list.concat([run_trial(gen, ids[i])], run_all(gen, ids, i + 1, n))

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

fun best_of(trials: List<Trial>): Trial =
  let n = list.length(trials)
  if n == 0 then empty_trial("no trials")
  else pick_best(trials, 1, n, trials[0])

-- Copy rich → stripped and drop the extra llm.chat draft step (genome edit).
fun mutate_strip_draft(src: String, dst: String): { ok: Bool, error: String } =
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let p = fs.patch(
    path = $"genomes/{dst}/workflows/main.md",
    hunks = [
      {
        old = "Draft notes, then extract a short title and 2-4 factual bullets. No preamble.",
        new = "Extract a short title and 2-4 factual bullets from the article. No preamble."
      },
      {
        old = """  let contents = fs.read(inputs.path)
  let draft = llm.chat(
    system = @system,
    prompt = contents.text,
    model = "deepseek4flash"
  )
  let facts = llm.object(
    prompt = draft,
    schema = schema(Facts),
    model = "deepseek4flash"
  )""",
        new = """  let contents = fs.read(inputs.path)
  let facts = llm.object(
    prompt = contents.text,
    schema = schema(Facts),
    model = "deepseek4flash"
  )"""
      }
    ]
  )
  { ok = p.ok, error = p.error }

fun main(_): { winner: String, trial_count: Int, generations: Int, results_path: String } =
  let ids0 = ["lean", "rich"]
  let trials0 = run_all(0, ids0, 0, list.length(ids0))
  let best0 = best_of(trials0)
  let mut = mutate_strip_draft("rich", "stripped")
  let elite = if best0.feasible then best0.id else "lean"
  let ids1 = if mut.ok then [elite, "stripped"] else [elite]
  let trials1 = run_all(1, ids1, 0, list.length(ids1))
  let best1 = best_of(trials1)
  let best = better(best0, best1)
  let trials = list.concat(trials0, trials1)
  let n = list.length(trials)
  let winner = if best.feasible then best.id else ""
  let report = {
    winner = winner,
    generations = 2,
    mutation = { id = "stripped", ok = mut.ok, error = mut.error, parent = "rich" },
    elite = elite,
    trials = trials
  }
  let _ = fs.write(path = "results.json", text = json.encode(report))
  {
    winner = winner,
    trial_count = n,
    generations = 2,
    results_path = "results.json"
  }
```
