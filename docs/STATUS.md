# Status

Last updated: 2026-07-15

## Current focus

**Spec pack** — normative docs for the greenfield engine (pml). No
implementation in this folder; this is the starting documentation for a
new repository.

## Done recently

- Multi-file design spec under `spec/`
- Documentation workflow + Cursor scaffold (`cursor-scaffold/`)
- Architecture, hwfi reference notes, example suite sketch

## Blockers

None for documentation. Implementation blocked until a greenfield repo
exists and this folder is moved to `docs/`.

## Next up

1. Create greenfield Haskell repo; rename this folder → `docs/`
2. Copy `cursor-scaffold/` → `.cursor/`
3. Scaffold Cabal package + empty modules matching [architecture.md](architecture.md)
4. Execute [TASKS.md](TASKS.md) milestone **M0** (kernel AST + parser)

## Open naming

Working title **pml** / CLI `pml` / fence `pml` is provisional.
