---
name: workflows/main
inputs:
  generations: Int
  model: String
outputs:
  winner: String
  trial_count: Int
  generations: Int
  results_path: String
effects: [Read, Write, Net, Meta]
---

# Evolve agent lab

Score slim coding-agent genomes on a fixed Python task, propose an LLM
patch mutation (with structural fallback), and iterate elite + child.

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
  task_ok: Bool,
  feasible: Bool,
  outcome_json: String,
  error: String
}

type PatchHunk = { old: String, new: String }

type Mutation = {
  rationale: String,
  hunks: List<PatchHunk>
}

type MutEvent = {
  gen: Int,
  parent: String,
  child: String,
  ok: Bool,
  via: String,
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
    task_ok = false,
    feasible = false,
    outcome_json = "null",
    error = err
  }

fun materialize(gen: Int, id: String): String =
  let trial_ws = $"trials/g{gen}/{id}"
  let _ = fs.copy(src = $"genomes/{id}", dst = $"candidates/{id}", overwrite = true)
  let _ = fs.mkdir(trial_ws)
  trial_ws

fun run_trial(gen: Int, id: String, prompt: String, model: String): Trial =
  let trial_ws = materialize(gen, id)
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
      task_ok = false,
      feasible = false,
      outcome_json = "null",
      error = chk.error
    }
  else
    let inv = meta.invoke(
      project = $"candidates/{id}",
      workspace = trial_ws,
      inputs = { prompt = prompt, model = model }
    )
    let spans = meta.read_spans(run_id = inv.run_id, workspace = trial_ws)
    let llm = meta.read_spans(
      run_id = inv.run_id,
      workspace = trial_ws,
      name_prefix = "llm."
    )
    let span_n = if spans.ok then list.length(spans.spans) else 0
    let llm_n = if llm.ok then list.length(llm.spans) else 0
    let outcome_json = json.encode(inv.outcome)
    let task_ok = text.contains(outcome_json, "\"ok\":true")
    let feasible = chk.ok && inv.ok && inv.status == "completed" && task_ok
    {
      gen = gen,
      id = id,
      check_ok = chk.ok,
      run_ok = inv.ok,
      status = inv.status,
      run_id = inv.run_id,
      span_count = span_n,
      llm_spans = llm_n,
      task_ok = task_ok,
      feasible = feasible,
      outcome_json = outcome_json,
      error = inv.error
    }

fun run_all(
  gen: Int,
  ids: List<String>,
  i: Int,
  n: Int,
  prompt: String,
  model: String
): List<Trial> =
  if i >= n then []
  else
    list.concat(
      [run_trial(gen, ids[i], prompt, model)],
      run_all(gen, ids, i + 1, n, prompt, model)
    )

fun better(a: Trial, b: Trial): Trial =
  if not(a.feasible) then b
  else if not(b.feasible) then a
  else if a.llm_spans < b.llm_spans then a
  else if b.llm_spans < a.llm_spans then b
  else if a.span_count < b.span_count then a
  else if b.span_count < a.span_count then b
  else a

fun worse(a: Trial, b: Trial): Trial =
  if better(a, b).id == a.id then b else a

fun pick_best(trials: List<Trial>, i: Int, n: Int, best: Trial): Trial =
  if i >= n then best
  else pick_best(trials, i + 1, n, better(best, trials[i]))

fun best_of(trials: List<Trial>): Trial =
  let n = list.length(trials)
  if n == 0 then empty_trial("no trials")
  else pick_best(trials, 1, n, trials[0])

fun pick_worst(trials: List<Trial>, i: Int, n: Int, worst: Trial): Trial =
  if i >= n then worst
  else pick_worst(trials, i + 1, n, worse(worst, trials[i]))

fun worst_of(trials: List<Trial>): Trial =
  let n = list.length(trials)
  if n == 0 then empty_trial("no trials")
  else pick_worst(trials, 1, n, trials[0])

-- Strip the deliberate warmup llm.chat from wasteful-style genomes.
fun fallback_strip_warmup(src: String, dst: String): { ok: Bool, error: String } =
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let p = fs.patch(
    path = $"genomes/{dst}/workflows/main.md",
    hunks = [
      {
        old = """  let _warmup = llm.chat(
    system = "Be brief.",
    prompt = "Acknowledge the coding task before starting.",
    model = inputs.model
  )
  let result = llm.agent_object(""",
        new = "  let result = llm.agent_object("
      }
    ]
  )
  if p.ok then { ok = true, error = "" }
  else
    let e = fs.edit(
      path = $"genomes/{dst}/workflows/main.md",
      old = "max_rounds = 16",
      new = "max_rounds = 8"
    )
    if e.ok then { ok = true, error = "fallback: shrunk max_rounds" }
    else { ok = false, error = p.error }

fun mutate_genome(
  src: String,
  dst: String,
  model: String
): { ok: Bool, error: String, rationale: String, via: String } =
  let src_body = fs.read($"genomes/{src}/workflows/main.md")
  let proposal = llm.object(
    prompt = $"Propose a single fs.patch that removes wasted LLM work from this coding-agent module (keep I/O and tools). Prefer deleting a warmup llm.chat if present.\n\nMODULE:\n{src_body.text}",
    schema = schema(Mutation),
    model = model
  )
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let p = fs.patch(
    path = $"genomes/{dst}/workflows/main.md",
    hunks = proposal.hunks
  )
  if p.ok then
    { ok = true, error = "", rationale = proposal.rationale, via = "llm_patch" }
  else
    let fb = fallback_strip_warmup(src, dst)
    {
      ok = fb.ok,
      error = fb.error,
      rationale = proposal.rationale,
      via = "fallback"
    }

fun evolve(
  g: Int,
  gens: Int,
  pop: List<String>,
  all_trials: List<Trial>,
  mutations: List<MutEvent>,
  prompt: String,
  model: String
): {
  trials: List<Trial>,
  mutations: List<MutEvent>,
  winner: String
} =
  let trials = run_all(g, pop, 0, list.length(pop), prompt, model)
  let merged = list.concat(all_trials, trials)
  let best = best_of(trials)
  if g + 1 >= gens then
    {
      trials = merged,
      mutations = mutations,
      winner = if best.feasible then best.id else ""
    }
  else
    let parent = worst_of(trials)
    let child = $"mut-g{g}"
    let src = if parent.id == "" then best.id else parent.id
    let mut = mutate_genome(src, child, model)
    let mut_row = {
      gen = g,
      parent = src,
      child = child,
      ok = mut.ok,
      via = mut.via,
      error = mut.error
    }
    let elite = if best.feasible then best.id else src
    let next_pop = if mut.ok then [elite, child] else [elite]
    evolve(
      g + 1,
      gens,
      next_pop,
      merged,
      list.concat(mutations, [mut_row]),
      prompt,
      model
    )

fun main(inputs: { generations: Int, model: String }): {
  winner: String,
  trial_count: Int,
  generations: Int,
  results_path: String
} =
  let gens = if inputs.generations < 1 then 1 else inputs.generations
  let prompt_file = fs.read("fixture/prompt.txt")
  let prompt = text.trim(prompt_file.text)
  let result = evolve(
    0,
    gens,
    ["wasteful", "tight"],
    [],
    [],
    prompt,
    inputs.model
  )
  let n = list.length(result.trials)
  let report = {
    winner = result.winner,
    generations = gens,
    mutations = result.mutations,
    trials = result.trials
  }
  let _ = fs.write(path = "results.json", text = json.encode(report))
  {
    winner = result.winner,
    trial_count = n,
    generations = gens,
    results_path = "results.json"
  }
```
