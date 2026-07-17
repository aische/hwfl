---
name: skills/echo-tool
skill:
  kind: callable
  summary: "Echo a message back as a tool"
  tags: [echo, demo]
inputs:
  msg: String
outputs:
  text: String
effects: []
---

# Echo tool

```hwfl
fun main(inputs): { text: String } = { text = inputs.msg }
```
