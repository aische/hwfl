---
name: skills/prefer-no-search
skill:
  kind: instruction
  summary: "Fixture skill that soft-prefers against lib/search"
  tags: [fixture, proposition]
---

# Prefer no search

## rules

Rules for this fixture:

- The agent should preferably not use lib/search when answering catalog questions.

Do not reconcile with require-search; semantic-check should project Prefer(¬a).
