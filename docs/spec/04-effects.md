# 04 — Effects

Effects (capabilities) classify what a module may do. They are **not**
full user-defined algebraic effects in v0.

## 1. Lattice (v0)

| Effect | Meaning |
|--------|---------|
| `Pure` | No host ops (implicit for pure functions) |
| `Read` | Read workspace, env, spans, run metadata |
| `Write` | Mutate workspace files |
| `Net` | LLM (and future HTTP) |
| `Exec` | Process spawn |
| `Parallel` | Use `par` / `join` |
| `Human` | `confirm` and similar gates |
| `Meta` | Invoke modules dynamically, eval, introspect other runs |

`Pure` is the bottom. There is no total order; allow-sets are finite
sets. `Pure` need not appear in annotations — absence of effects means
pure.

## 2. Rules

1. Every host op declares a required effect set.
2. A function’s effect set must cover the ops (and calls) in its body.
3. A module’s `effects:` frontmatter is the ceiling for its `main` and
   exports called from outside (library internals can be tighter).
4. Project `effects.deny` always wins.
5. `Exec` additionally requires `project.json` `exec.allow` non-empty.
6. Calling another module unions its residual effects into the caller
   (or requires the callee’s effects ⊆ caller allow-set).

## 3. Inference

- Infer minimal effects for local `fun`s.
- Check against annotations when present.
- Ambiguous / inferred-too-large is a check warning? **v0: hard error** if
  inferred ⊈ declared.

## 4. Why not “just IO”

Distinguishing `Net` vs `Write` vs `Human` enables:

- Running pure tests without keys
- Policy: “this agent may not exec”
- Clearer spans and audits

## 5. Ambient `ctx`

Reading `ctx.run` / `ctx.env` requires at least `Read`.  
Writing via `fs.*` requires `Write`.  
`llm.*` requires `Net`.

## 6. Deferrals

- Effect polymorphism (`forall e. …`) — **[defer]**
- User-defined effects / handlers — **[defer]**
- Automatic effect weakening through pure callbacks — keep simple in v0
