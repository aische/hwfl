# Stdlib policy (informative)

Normative host set: [spec/05-host-ops.md](spec/05-host-ops.md).
Module layout / imports: [spec/01-modules.md](spec/01-modules.md).

Everything that is not a privileged host op belongs as **hwfl markdown
modules** — either the shipped **stdlib** (`hwfl/…`) or **project-local**
`lib/…`. Prefer MCP or those modules for new capabilities; add host ops
only when the language cannot express the need. See [TASKS.md](TASKS.md).

## Polymorphism first

A useful `hwfl/list.map` needs **value / let-polymorphism** (`List<a>`,
`(a) -> b`, …). That is now in check — do **not** ship monomorphic clones
(`map_string`, …). Effect polymorphism (`forall e. …`) stays deferred
([spec/04-effects.md](spec/04-effects.md)).

## Three layers (do not conflate)

| Layer | Location | How found | Examples |
| ----- | -------- | --------- | -------- |
| **Prelude / host** | Haskell | Always in scope | `list.length`, `fs.read`, `text.trim`, `+` |
| **Stdlib pack** | Markdown under a pack root | Imports `hwfl/…`; pack root from env or default | `hwfl/list`, `hwfl/option` |
| **Project `lib/`** | `<project>/lib/*.md` | Same as today: discovered under the project | `lib/story_claims` |

Projects do **not** invent a search path in `project.json`. The loader
injects `hwfl/*` from the pack the same way the process already owns
prelude/host — except stdlib modules are ordinary checked markdown.

## Stdlib pack location

**Source of truth in this repo:** `stdlib/` at the repository root (files
whose frontmatter `name` is `hwfl/list`, `hwfl/string`, …).

**At check/run time**, resolve the pack root as:

1. **`HWFL_STDLIB`** — if set, must be a directory containing the pack
   (e.g. `list.md` or nested layout documented with the loader).
2. Else a **sensible default**: the stdlib shipped with the install
   (Cabal/data-files or directory next to the `hwfl` binary). For a
   repo checkout / tests, defaulting to `<repo>/stdlib` is fine.

Optional later: library drivers may pass an explicit pack root; CLI still
honours `HWFL_STDLIB` over the built-in default.

The pack is part of the **interpreter install**, not the workspace
sandbox. Do not require copying `stdlib/` into every project.

### Import resolution

- `imports: [hwfl/list]` → load `hwfl/list` from the pack root; merge into
  the project module map before check/eval.
- `imports: [lib/foo]` → project tree only (`lib/foo.md` under the
  project). No fallback to the pack under a `lib/` alias (keeps global vs
  local obvious).
- Project modules must not claim qnames under `hwfl/` (reject at load).
- Stdlib modules participate in the import graph like any library
  (`effects: []` for pure helpers).

### Call site

```yaml
imports:
  - hwfl/list
  - lib/story_claims
```

```hwfl
hwfl/list.map(xs, f)
lib/story_claims.dedupe(rows)
```

## Candidate stdlib modules

| Module | Contents |
| ------ | -------- |
| `hwfl/list` | map, filter, fold, flat_map, unique_by, take, drop, … (build on prelude `list.length` / `list.concat`) |
| `hwfl/record` | merge, pick, map_fields |
| `hwfl/string` | split, replace, join, … (avoid duplicating prelude `text.*` without cause) |
| `hwfl/json` | helpers over `Json` / `json.encode` |
| `hwfl/option` / `hwfl/result` | combinators |
| `hwfl/text` | only if migrating metrics/similarity out of the Pure prelude |

Pure prelude keeps minimal operators and foundations that are painful as
library code (`list.length` / `list.concat`, arithmetic/ord, `schema` /
`tool`, current `text.*` until a migration pass).

## Project `lib/`

Author and domain helpers stay in the project’s `lib/`. Factor large
examples (`real-story-writer`, `semantic-check`, …) into project modules;
graduate only generic pieces into `stdlib/` / `hwfl/…`.

## Pure operators in the prelude

Minimal operators that are painful as library functions may be kernel
builtins (still **Pure**, not host ops):

- arithmetic `+ - * /` — same numeric sort only (`Int` or `Float`); **no**
  `String` `+` (use interpolation or `hwfl/string`)
- comparisons `== !=` — comparable sorts (bases, plus structural `List` /
  records); `String` ≅ `FileRef` only via dedicated **path coercibility**
- ordered `< ≤ > ≥` — same sort among `Int` | `Float` | `String` | `FileRef`
- boolean `&& || not` — `&&` / `||` short-circuit (desugar to `if`)

Overloading is resolved at applications of these ops (`Hwfl.Check.Overload`);
bare operator references have no principal type. Prefer overloading only
where types stay obvious.

## Anti-pattern

If you are about to add `host.list_unique_by` in Haskell, stop — write
`hwfl/list.unique_by` in hwfl first (after polymorphism).
