---
name: workflows/main
inputs:
    mode: String
    model: String
outputs:
    ok: Bool
    tape: String
    rounds: Int
    text: String
effects: [Read, Write, Net]
examples:
  - name: selftest
    inputs:
      mode: selftest
      model: mock
  - name: agent
    inputs:
      mode: agent
      model: deepseek4flash
---

## system

You are a Turing-machine controller. You do not invent transitions.

Alphabet: `1`, `+`, `_` (blank). States: `q0`, `q1`, `q2`, `H` (halt).
Directions: `L`, `R`, `N`.

Transition table δ(state, symbol) → (new_state, new_symbol, direction):

| state | symbol | new_state | new_symbol | dir |
|-------|--------|-----------|------------|-----|
| q0    | 1      | q0        | 1          | R   |
| q0    | +      | q1        | 1          | R   |
| q1    | 1      | q1        | 1          | R   |
| q1    | _      | q2        | _          | L   |
| q2    | 1      | H         | _          | N   |

This machine unary-adds: rewrite `+` as `1`, then erase one trailing `1`.
Example: `11+1` becomes `111`.

Protocol:
1. Call `tm_read`.
2. Look up exactly one row for (state, value). If none, stop and explain.
3. Call `tm_step` with that row's new_state, new_symbol, dir.
4. Repeat until `halted` is true (or `tm_step` returns halted).
5. Then reply with one short line: final significant tape (ignore `_`).

Never call `fs_*`. Never invent states or symbols outside the table.

## body

```hwfl
fun marks(n: Int): String =
  if n <= 0 then ""
  else if n == 1 then "*"
  else $"* {marks(n - 1)}"

fun join_cells(xs: List<String>, i: Int, n: Int): String =
  if i >= n then ""
  else if i == n - 1 then xs[i]
  else $"{xs[i]} {join_cells(xs, i + 1, n)}"

fun take_cells(xs: List<String>, k: Int, i: Int): List<String> =
  if i >= k then []
  else list.concat([xs[i]], take_cells(xs, k, i + 1))

fun rstrip_blanks(xs: List<String>, n: Int): List<String> =
  if n <= 0 then []
  else if xs[n - 1] == "_" then rstrip_blanks(xs, n - 1)
  else take_cells(xs, n, 0)

fun set_at(xs: List<String>, idx: Int, v: String, j: Int, n: Int): List<String> =
  if j >= n then []
  else if j == idx then list.concat([v], set_at(xs, idx, v, j + 1, n))
  else list.concat([xs[j]], set_at(xs, idx, v, j + 1, n))

fun ensure_index(xs: List<String>, head: Int, n: Int): List<String> =
  if head < n then xs
  else ensure_index(list.concat(xs, ["_"]), head, n + 1)

fun write_cell(xs: List<String>, head: Int, v: String): List<String> =
  let ys = ensure_index(xs, head, list.length(xs))
  set_at(ys, head, v, 0, list.length(ys))

fun move_head(
  xs: List<String>,
  head: Int,
  dir: String
): { cells: List<String>, head: Int } =
  if dir == "R" then
    { cells = xs, head = head + 1 }
  else if dir == "L" then
    if head <= 0 then
      { cells = list.concat(["_"], xs), head = 0 }
    else
      { cells = xs, head = head - 1 }
  else
    { cells = xs, head = head }

fun valid_dir(d: String): Bool =
  d == "L" || d == "R" || d == "N"

fun valid_sym(s: String): Bool =
  s == "1" || s == "+" || s == "_"

fun seed(): Bool =
  let _ = fs.write(path = "machine/state", text = "q0")
  let _ = fs.write(path = "machine/head", text = "")
  let _ = fs.write(path = "machine/cells", text = "1 1 + 1")
  true

fun load_machine(): { state: String, head: Int, cells: List<String> } =
  let st = text.trim(fs.read("machine/state").text)
  let hd = list.length(text.words(text.trim(fs.read("machine/head").text)))
  let cells = text.words(text.trim(fs.read("machine/cells").text))
  { state = st, head = hd, cells = cells }

fun save_machine(state: String, head: Int, cells: List<String>): Bool =
  let _ = fs.write(path = "machine/state", text = state)
  let _ = fs.write(path = "machine/head", text = marks(head))
  let _ = fs.write(
    path = "machine/cells",
    text = join_cells(cells, 0, list.length(cells))
  )
  true

fun significant_tape(cells: List<String>): String =
  let trimmed = rstrip_blanks(cells, list.length(cells))
  join_cells(trimmed, 0, list.length(trimmed))

fun tm_read(): { state: String, value: String, halted: Bool } =
  let m = load_machine()
  let n = list.length(m.cells)
  let v =
    if m.head >= n then "_"
    else if m.head < 0 then "_"
    else m.cells[m.head]
  { state = m.state, value = v, halted = m.state == "H" }

fun tm_step(
  new_state: String,
  new_value: String,
  direction: String
): { ok: Bool, halted: Bool, error: String, tape: String, head: Int, state: String } =
  let m = load_machine()
  let cur_tape = join_cells(m.cells, 0, list.length(m.cells))
  if m.state == "H" then
    {
      ok = false,
      halted = true,
      error = "already halted",
      tape = cur_tape,
      head = m.head,
      state = m.state
    }
  else if not(valid_dir(direction)) then
    {
      ok = false,
      halted = false,
      error = "direction must be L, R, or N",
      tape = cur_tape,
      head = m.head,
      state = m.state
    }
  else if not(valid_sym(new_value)) then
    {
      ok = false,
      halted = false,
      error = "symbol must be 1, +, or _",
      tape = cur_tape,
      head = m.head,
      state = m.state
    }
  else if new_state == "" then
    {
      ok = false,
      halted = false,
      error = "new_state must be non-empty",
      tape = cur_tape,
      head = m.head,
      state = m.state
    }
  else
    let cells1 = write_cell(m.cells, m.head, new_value)
    let moved = move_head(cells1, m.head, direction)
    let _ = save_machine(new_state, moved.head, moved.cells)
    let tape = join_cells(moved.cells, 0, list.length(moved.cells))
    let halted = new_state == "H"
    let _ = obs.log(
      level = "info",
      message = $"tm_step → {new_state} head={moved.head} [{tape}]",
      fields = {
        state = new_state,
        head = moved.head,
        cells = tape,
        direction = direction,
        wrote = new_value,
        halted = halted
      }
    )
    {
      ok = true,
      halted = halted,
      error = "",
      tape = tape,
      head = moved.head,
      state = new_state
    }

fun run_selftest(): { ok: Bool, tape: String, rounds: Int, text: String } =
  let _ = seed()
  let _ = tm_step("q0", "1", "R")
  let _ = tm_step("q0", "1", "R")
  let _ = tm_step("q1", "1", "R")
  let _ = tm_step("q1", "1", "R")
  let _ = tm_step("q2", "_", "L")
  let last = tm_step("H", "_", "N")
  let m = load_machine()
  let tape = significant_tape(m.cells)
  {
    ok = last.ok && last.halted && tape == "1 1 1",
    tape = tape,
    rounds = 0,
    text = "selftest"
  }

fun run_agent(model: String): { ok: Bool, tape: String, rounds: Int, text: String } =
  let _ = seed()
  let result = llm.agent(
    system = @system,
    prompt = "Run the unary-add machine on the seeded tape until halt. Use tm_read and tm_step only.",
    tools = [tool(tm_read), tool(tm_step)],
    model = model,
    max_rounds = 40
  )
  let m = load_machine()
  let tape = significant_tape(m.cells)
  {
    ok = m.state == "H" && tape == "1 1 1",
    tape = tape,
    rounds = result.rounds,
    text = result.text
  }

fun main(inputs: { mode: String, model: String }): {
  ok: Bool,
  tape: String,
  rounds: Int,
  text: String
} =
  if inputs.mode == "selftest" then
    run_selftest()
  else
    run_agent(inputs.model)
```
