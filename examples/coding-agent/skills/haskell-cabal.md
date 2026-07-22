---
name: skills/haskell-cabal
skill:
  kind: instruction
  summary: "Small cabal library + test suite layout and verify commands"
  tags: [haskell, cabal, tasty, hunit]
---

# Haskell / cabal

Prefer a small library package with an in-tree test suite.

Write `.gitignore` early (before `cabal build` / `cabal test`):

```
dist-newstyle/
dist/
.cabal-sandbox/
cabal.sandbox.config
*.o
*.hi
*.chi
*.chs.h
.DS_Store
```

Suggested layout:

- `mylib.cabal` (or project-named `.cabal`) — `library` + `test-suite`
- `src/Lib.hs` — e.g. `add :: Int -> Int -> Int`
- `test/Spec.hs` — HUnit / tasty asserting `add 2 3 == 5`
- optional `cabal.project` with `packages: .`

Verify:

```bash
cabal build
cabal test
```

For the smallest demo, a single-module `runhaskell`-style tree is OK only if
the prompt allows it; otherwise use cabal so `exec.run` can call `cabal`.

Rules:

- Pin a recent `cabal-version` and GHC2021 (or the project's convention).
- Avoid network-heavy dependency sets; stdlib + tasty/HUnit is enough.
- On compile errors, read stderr, edit, re-run `cabal test`.
