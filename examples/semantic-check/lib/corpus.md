---
name: lib/corpus
effects: []
imports:
  - types/main
---

## body

```hwfl
fun sum_entropy(xs: List<Slice>, i: Int, n: Int): Float =
  if i >= n then 0.0
  else xs[i].entropy + sum_entropy(xs, i + 1, n)

fun corpus_hints(slices: List<Slice>): List<Finding> =
  let n = list.length(slices)
  corpus_entropy_outliers(slices, mean_entropy(slices, n), 0, n)

fun mean_entropy(slices: List<Slice>, n: Int): Float =
  if n == 0 then 0.0
  else sum_entropy(slices, 0, n) / float_of_int(n)

fun float_of_int(n: Int): Float =
  if n <= 0 then 0.0
  else 1.0 + float_of_int(n - 1)

fun corpus_entropy_outliers(slices: List<Slice>, mean: Float, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else
    let s = slices[i]
    let rest = corpus_entropy_outliers(slices, mean, i + 1, n)
    if s.entropy > mean + 1.0 then
      list.concat(
        [{
          severity = "info",
          category = "corpus",
          file = s.file,
          claim = $"Section word-entropy {s.entropy} above local mean {mean}",
          evidence = $"{s.id} ({s.title})",
          suggestion = "Long or varied prose; inspect only if guidance feels scattered"
        }],
        rest
      )
    else rest

fun sentence_usable(s: String): Bool =
  text.metrics(s).chars > 40

fun redundancy_sent_pairs(sents: List<String>, slice: Slice, i: Int, j: Int, n: Int, remaining: Int): List<Finding> =
  if remaining <= 0 then []
  else if i >= n then []
  else if j >= n then redundancy_sent_pairs(sents, slice, i + 1, i + 2, n, remaining)
  else
    let a = sents[i]
    let b = sents[j]
    let rest = redundancy_sent_pairs(sents, slice, i, j + 1, n, remaining)
    if not(sentence_usable(a)) then rest
    else if not(sentence_usable(b)) then rest
    else
      let score = text.similarity(a, b)
      if score > 0.9 then
        list.concat(
          [{
            severity = "warning",
            category = "redundancy",
            file = slice.file,
            claim = $"Near-duplicate sentences in {slice.id}",
            evidence = $"A: {a} | B: {b}",
            suggestion = "Keep one wording or merge into a single rule"
          }],
          redundancy_sent_pairs(sents, slice, i, j + 1, n, remaining - 1)
        )
      else rest

fun redundancy_in_slice(slice: Slice, remaining: Int): List<Finding> =
  let sents = text.split_sentences(slice.body)
  redundancy_sent_pairs(sents, slice, 0, 1, list.length(sents), remaining)

fun redundancy_all(slices: List<Slice>, i: Int, n: Int, remaining: Int): List<Finding> =
  if i >= n || remaining <= 0 then []
  else
    let here = redundancy_in_slice(slices[i], remaining)
    let used = list.length(here)
    list.concat(here, redundancy_all(slices, i + 1, n, remaining - used))
```
