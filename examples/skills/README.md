# Skills demo

Minimal agent toolbox with `skill.discover` / `skill.load` plus project
skills under `skills/`.

```bash
cabal run hwfl -- check examples/skills
cabal run hwfl -- run examples/skills --llm-provider mock
```

Instruction skill `skills/shell-repair-guide` injects prose mid-loop.
Callable `skills/echo-note` can be loaded to expand the advertised tool set.
