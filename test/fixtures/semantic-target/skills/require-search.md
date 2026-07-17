---
name: skills/require-search
skill:
  kind: instruction
  summary: "Fixture skill that requires lib/search"
  tags: [fixture, obligation]
---

# Require search

## rules

Rules for this fixture:

- The agent must use lib/search for all catalog lookups.

Do not soften this rule; semantic-check should extract a must obligation.
