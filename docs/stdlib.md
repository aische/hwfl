# Stdlib policy (informative)

Normative host set: [spec/05-host-ops.md](spec/05-host-ops.md).

Everything else should start as **pml modules** under `lib/` in the
greenfield repo (and eventually a bootstrapped stdlib shipped with the
CLI).

## Suggested early `lib/` modules

| Module | Contents |
|--------|----------|
| `lib/list` | map, filter, fold, concat, flat_map, unique_by, take, drop, length |
| `lib/record` | merge, pick, map_fields |
| `lib/string` | split, trim, contains, replace |
| `lib/json` | parse/print helpers over `Json` |
| `lib/option` / `lib/result` | combinators |
| `lib/text` | metrics, similarity — **v0**: pure prelude `text.*` (M8); later migrate to module |

Pure prelude also exposes `list.length` / `list.concat` and `md.sections` so
authors can write recursive list helpers before cons patterns land.

## Pure operators in the prelude

Minimal operators that are painful as library functions may be kernel
builtins (still **Pure**, not host ops):

- arithmetic `+ - * /` — same numeric sort only (`Int` or `Float`); **no**
  `String` `+` (use interpolation or `lib/string`)
- comparisons `== !=` — comparable sorts (bases, plus structural `List` /
  records); `String` ≅ `FileRef` only via dedicated **path coercibility**
- ordered `< ≤ > ≥` — same sort among `Int` | `Float` | `String` | `FileRef`
- boolean `&& || not`

Overloading is resolved at applications of these ops (`Pml.Check.Overload`);
bare operator references have no principal type. Prefer overloading only
where types stay obvious.

## Anti-pattern

If you are about to add `host.list_unique_by` in Haskell, stop — write
`lib/list.unique_by` in pml first.
