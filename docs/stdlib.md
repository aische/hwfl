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
| `lib/text` | metrics, similarity (port from hwfi builtins when dogfooding) |

## Pure operators in the prelude

Minimal operators that are painful as library functions may be kernel
builtins (still **Pure**, not host ops):

- arithmetic `+ - * /`
- comparisons `== != < …`
- boolean `&& || not`

Prefer overloading only where types stay obvious (`==` on comparable
types). Do not add string `+`; use interpolation or `lib/string`.

## Anti-pattern

If you are about to add `host.list_unique_by` in Haskell, stop — write
`lib/list.unique_by` in pml first.
