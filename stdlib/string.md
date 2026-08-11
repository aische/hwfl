---
name: hwfl/string
effects: []
---

# hwfl/string

String helpers that compose the Pure prelude `text.*` ops. Prefer
`text.trim` / `text.contains` / … directly when a one-liner is enough.

## body

```hwfl
fun is_empty(s: String): Bool =
  s == ""

fun join_with(parts: List<String>, sep: String): String =
  join_with_go(parts, sep, 0, list.length(parts))

fun join_with_go(parts: List<String>, sep: String, i: Int, n: Int): String =
  if i >= n then ""
  else if i == n - 1 then parts[i]
  else $"{parts[i]}{sep}{join_with_go(parts, sep, i + 1, n)}"

fun words(s: String): List<String> =
  text.words(s)

fun trim(s: String): String =
  text.trim(s)

fun contains(haystack: String, needle: String): Bool =
  text.contains(haystack, needle)

fun starts_with(s: String, prefix: String): Bool =
  text.starts_with(s, prefix)

fun strip_suffix(s: String, suffix: String): String =
  text.strip_suffix(s, suffix)
```
