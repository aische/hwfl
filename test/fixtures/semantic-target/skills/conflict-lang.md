---
name: skills/conflict-lang
skill:
  kind: instruction
  summary: "Fixture skill with intentional language-version conflict"
  tags: [fixture, contradiction]
---

# Language version

## rules

Rules for this fixture:

- Pin the project to GHC2021 for all modules.
- Always use Haskell2010 as the language standard.

Do not resolve the conflict in this file; semantic-check should flag it.
