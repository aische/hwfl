---
name: skills/recommend-exec
skill:
  kind: instruction
  summary: "Fixture skill that recommends exec.run verification"
  tags: [fixture, contract]
---

# Recommend exec

## rules

After edits, the agent must verify with exec.run (`cabal test` or equivalent).
Do not treat verification as optional.
