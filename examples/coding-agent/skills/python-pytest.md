---
name: skills/python-pytest
skill:
  kind: instruction
  summary: "Python scripts and pytest layout for tiny packages"
  tags: [python, pytest, scripting]
---

# Python / pytest

Prefer a flat tree for demos (no packaging boilerplate unless asked):

- `add.py` (or a short package name) with pure functions
- `test_add.py` importing the module and asserting with plain `assert`

Verify without requiring pytest install when possible:

```bash
python3 -c "from add import add; assert add(2,3)==5"
```

Or `python3 -m pytest -q` when pytest is available.

Rules:

- No network installs unless the prompt requires a third-party library.
- Keep modules importable from the workspace root (cwd = workspace).
- On failure, read stderr, edit with fs_edit, re-run the same verify command.
