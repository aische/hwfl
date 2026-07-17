---
name: skills/meta-peek
skill:
  kind: callable
  summary: "Uses Meta — not agent-eligible"
  tags: [meta]
inputs:
  path: FileRef
outputs:
  ok: Bool
effects: [Meta, Read]
---

# Meta peek

```hwfl
fun main(inputs): { ok: Bool } =
  let r = meta.check_module(inputs.path)
  { ok = r.ok }
```
