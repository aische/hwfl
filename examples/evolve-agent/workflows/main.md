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

Score slim coding-agent genomes on a seeded broken Python fixture, mutate
with an operator menu (LLM patch + structural fallbacks), reject no-ops,
and iterate elite + child.

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
  operator: String,
  rationale: String,
  hunks: List<PatchHunk>
}

type MutEvent = {
  gen: Int,
  parent: String,
  child: String,
  ok: Bool,
  via: String,
  operator: String,
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
  let _ = fs.copy(src = "fixture/project", dst = trial_ws, overwrite = true)
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

fun genome_path(id: String): String = $"genomes/{id}/workflows/main.md"

-- Structural operators (deterministic). Each copies src → dst then edits.
fun op_strip_warmup(src: String, dst: String): { ok: Bool, error: String } =
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let before = fs.read(genome_path(dst))
  let p = fs.patch(
    path = genome_path(dst),
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
  let after = fs.read(genome_path(dst))
  if p.ok && before.text != after.text then { ok = true, error = "" }
  else { ok = false, error = "strip_warmup: no change" }

fun op_shrink_rounds(src: String, dst: String): { ok: Bool, error: String } =
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let before = fs.read(genome_path(dst))
  let e16 = fs.edit(path = genome_path(dst), old = "max_rounds = 16", new = "max_rounds = 8")
  let e8 =
    if e16.ok then { ok = true }
    else fs.edit(path = genome_path(dst), old = "max_rounds = 8", new = "max_rounds = 4")
  let after = fs.read(genome_path(dst))
  if (e16.ok || e8.ok) && before.text != after.text then { ok = true, error = "" }
  else { ok = false, error = "shrink_rounds: no change" }

fun op_drop_fs_list(src: String, dst: String): { ok: Bool, error: String } =
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let before = fs.read(genome_path(dst))
  let p = fs.patch(
    path = genome_path(dst),
    hunks = [
      {
        old = """      tool(skill.load),
      tool(fs.list),
      tool(fs.read),""",
        new = """      tool(skill.load),
      tool(fs.read),"""
      }
    ]
  )
  let after = fs.read(genome_path(dst))
  if p.ok && before.text != after.text then { ok = true, error = "" }
  else { ok = false, error = "drop_fs_list: no change" }

fun apply_named_op(op: String, src: String, dst: String): { ok: Bool, error: String } =
  if op == "strip_warmup" then op_strip_warmup(src, dst)
  else if op == "shrink_rounds" then op_shrink_rounds(src, dst)
  else if op == "drop_fs_list" then op_drop_fs_list(src, dst)
  else { ok = false, error = $"unknown operator: {op}" }

-- Try operators starting at gen offset so later gens explore different edits.
fun fallback_ops(
  src: String,
  dst: String,
  ops: List<String>,
  start: Int,
  i: Int,
  n: Int
): { ok: Bool, error: String, operator: String } =
  if i >= n then { ok = false, error = "all operators failed", operator = "" }
  else
    let op = ops[(start + i) - ((start + i) / n) * n]
    let r = apply_named_op(op, src, dst)
    if r.ok then { ok = true, error = "", operator = op }
    else fallback_ops(src, dst, ops, start, i + 1, n)

fun mutate_genome(
  src: String,
  dst: String,
  model: String,
  gen: Int
): { ok: Bool, error: String, rationale: String, via: String, operator: String } =
  let ops = ["strip_warmup", "shrink_rounds", "drop_fs_list"]
  let src_body = fs.read(genome_path(src))
  let proposal = llm.object(
    prompt = $"Pick ONE operator from [strip_warmup, shrink_rounds, drop_fs_list] and emit exact fs.patch hunks that apply it to this coding-agent module. Hunks must change the file (no identity patches). Prefer strip_warmup if a warmup llm.chat is present, else shrink_rounds, else drop_fs_list.\n\nMODULE:\n{src_body.text}",
    schema = schema(Mutation),
    model = model
  )
  let _ = fs.copy(src = $"genomes/{src}", dst = $"genomes/{dst}", overwrite = true)
  let before = fs.read(genome_path(dst))
  let p = fs.patch(path = genome_path(dst), hunks = proposal.hunks)
  let after = fs.read(genome_path(dst))
  if p.ok && before.text != after.text then
    {
      ok = true,
      error = "",
      rationale = proposal.rationale,
      via = "llm_patch",
      operator = proposal.operator
    }
  else
    let fb = fallback_ops(src, dst, ops, gen, 0, list.length(ops))
    {
      ok = fb.ok,
      error = fb.error,
      rationale = proposal.rationale,
      via = "fallback",
      operator = fb.operator
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
    let mut = mutate_genome(src, child, model, g)
    let mut_row = {
      gen = g,
      parent = src,
      child = child,
      ok = mut.ok,
      via = mut.via,
      operator = mut.operator,
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
