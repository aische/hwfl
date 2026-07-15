# Cursor scaffold

Copy this directory to the **repository root** as `.cursor/` when creating
the greenfield project:

```bash
cp -R docs/cursor-scaffold/.cursor-tmp  # or:
mkdir -p .cursor
cp -R cursor-scaffold/rules .cursor/rules
cp -R cursor-scaffold/skills .cursor/skills
```

If this pack was already renamed to `docs/`:

```bash
cp -R docs/cursor-scaffold/rules .cursor/rules
cp -R docs/cursor-scaffold/skills .cursor/skills
```

Rules assume documentation lives at `docs/STATUS.md`, `docs/TASKS.md`, etc.
