# Prelude

Always in scope. Pure. No snapshot. For `map` / `filter` / `join_with`,
import [stdlib](stdlib.md).

## `list`

### `list.length`

**Signature:** `List<a> -> Int`

```hwfl
list.length([1, 2, 3])    -- 3
list.length([])           -- 0
```

### `list.concat`

**Signature:** `(List<a>, List<a>) -> List<a>`

```hwfl
list.concat([1, 2], [3])  -- [1, 2, 3]
```

Named form: `list.concat(left = xs, right = ys)`.

## `int`

### `int.to_float`

**Signature:** `Int -> Float`

```hwfl
int.to_float(2) * 1.5    -- 3.0
```

Traps if the integer cannot be a finite `Float` (magnitude beyond about
`1.8e308`). Integers past about `2^53` are finite but not exact.

## `float`

`Float` to `Int`. Arithmetic stays same-sort; convert explicitly.

| Op | Towards | `1.9` | `-1.9` | half (`.5`) |
|----|---------|-------|--------|-------------|
| `float.trunc` | zero | `1` | `-1` | truncated |
| `float.floor` | −∞ | `1` | `-2` | — |
| `float.ceil` | +∞ | `2` | `-1` | — |
| `float.round` | nearest, ties to even | `2` | `-2` | `0.5 → 0`, `1.5 → 2`, `2.5 → 2` |

```hwfl
float.round(3.7) + 1     -- 5
float.floor(0.0 - 1.1)   -- -2
```

## `text`

Curried; two-argument calls `text.contains(hay, needle)` work.

### `text.metrics`

**Signature:** `String -> { chars: Int, tokens: Int, lines: Int, entropy: Float, uniqueness: Float }`

Whitespace-aware token/line counts plus simple entropy / uniqueness
scores.

### `text.similarity`

**Signature:** `String -> String -> Float`

### `text.contains`

**Signature:** `String -> String -> Bool` — haystack then needle.

### `text.split_sentences`

**Signature:** `String -> List<String>`

### `text.words`

**Signature:** `String -> List<String>`

### `text.strip_suffix`

**Signature:** `String -> String -> String` — string then suffix. If the
string does not end with the suffix, it is returned unchanged.

### `text.trim`

**Signature:** `String -> String`

### `text.starts_with`

**Signature:** `String -> String -> Bool`

### `text.normalize_token`

**Signature:** `String -> String`

Strips wrapping punctuation and backticks. Useful when matching
identifiers copied from prose.

### `text.is_qname`

**Signature:** `String -> Bool`

Conservative check for a module qname (`root/seg…`). Rejects paths,
URLs, globs, and casual English slash compounds.

## `md.sections`

**Signature:** `String -> List<{ slug: String, title: String, body: String }>`

Parse markdown into heading sections (same slug rules as `@slug`).

## `json.encode`

**Signature:** encodable value → `String`

Same renderability rule as interpolation: records, lists, options,
results, and base types. Not functions, secrets, or bytes.

```hwfl
json.encode({ ok = true, n = 1 })
```

## `tool` / `schema`

See [syntax](../language.md). `tool` accepts any function or host op.

## `ctx.run`

```hwfl
ctx.run.id            -- String, current run id
ctx.run.started_at    -- String
```

Available on every run. Reading it does not require `Read`. There is no
`ctx.env`.

## Operators

Documented under [syntax](../language.md) and the
[cheatsheet](../cheatsheet.md). Arithmetic is same-sort only; convert
with `int.to_float` / `float.round` (no `String +`).
