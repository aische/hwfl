---
name: skills/forbid-search
skill:
  kind: instruction
  summary: "Fixture skill that forbids lib/search"
  tags: [fixture, obligation]
---

# Forbid search

## rules

Rules for this fixture:

- The agent must not use lib/search under any circumstance.

Do not reconcile with require-search; semantic-check should extract must_not.
