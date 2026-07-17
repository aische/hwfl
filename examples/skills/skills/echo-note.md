---
name: skills/echo-note
skill:
  kind: callable
  summary: "Echo a short note (demo domain tool)"
  tags: [demo]
inputs:
  msg: String
outputs:
  text: String
effects: []
---

# Echo note

```hwfl
fun main(inputs): { text: String } = { text = inputs.msg }
```
