---
name: workflows/main
inputs: {}
outputs:
  text: String
  rounds: Int
effects: [Meta, Read, Net]
---

# Skills agent demo

Explicit meta-tools only — discover/load are listed in `tools`, not
auto-injected.

## system

You fix shell scripts. Discover and load skills before editing.

```hwfl
fun main(_): { text: String, rounds: Int } =
  let result = llm.agent(
    system = @system,
    prompt = "Prepare to repair a shell script using skills.",
    tools = [
      tool(skill.discover),
      tool(skill.load)
    ],
    model = "smart",
    max_rounds = 8
  )
  { text = result.text, rounds = result.rounds }
```
