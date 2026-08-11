---
name: lib/speech
effects: []
imports:
  - types/main
---

## body

```hwfl
fun is_directive(sentence: String): Bool =
  text.contains(sentence, "must ")
    || text.contains(sentence, "Must ")
    || text.contains(sentence, "should ")
    || text.contains(sentence, "Should ")
    || text.contains(sentence, "always ")
    || text.contains(sentence, "Always ")
    || text.contains(sentence, "never ")
    || text.contains(sentence, "Never ")
    || text.contains(sentence, "do not ")
    || text.contains(sentence, "Do not ")

fun speech_in_slice(s: Slice): List<Finding> =
  let sents = text.split_sentences(s.body)
  speech_sents(sents, s, 0, list.length(sents), false)

fun is_agent_section(title: String): Bool =
  text.contains(title, "agent")
    || text.contains(title, "Agent")
    || text.contains(title, "system")
    || text.contains(title, "System")
    || text.contains(title, "reviewer")
    || text.contains(title, "Reviewer")

fun speech_sents(sents: List<String>, s: Slice, i: Int, n: Int, saw: Bool): List<Finding> =
  if i >= n then
    if saw then []
    else if is_agent_section(s.title) then
      [{
        severity = "warning",
        category = "speech_act",
        file = s.file,
        claim = "Agent section lacks directive language",
        evidence = s.id,
        suggestion = "Add explicit must/should guidance for the agent"
      }]
    else []
  else
    let sent = sents[i]
    let next = is_directive(sent) || saw
    speech_sents(sents, s, i + 1, n, next)

fun speech_all(slices: List<Slice>, i: Int, n: Int): List<Finding> =
  if i >= n then []
  else list.concat(speech_in_slice(slices[i]), speech_all(slices, i + 1, n))
```
