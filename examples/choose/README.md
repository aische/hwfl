# Choose demo

N-way `human.choice` gate. Pause with exit `3`, then resolve with
`hwfl choose`, or drive the gate in-process with `--interactive`.

```bash
cabal run hwfl -- check examples/choose
cabal run hwfl -- run examples/choose --workspace /tmp/hwfl-choose --interactive
```

Without `--interactive`, resume after pause:

```bash
cabal run hwfl -- run examples/choose --workspace /tmp/hwfl-choose
cabal run hwfl -- choose /tmp/hwfl-choose <run-id> --select staging
```
