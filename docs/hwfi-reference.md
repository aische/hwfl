# hwfi reference

Keep the **hwfi** repository adjacent when porting behaviour. Copy code
only when the behaviour is still desired and the new design does not
contradict it.

## Reuse (ideas / tests / algorithms)

Frame/cursor resume, `par` + confirm freeze, workspace sandbox, secret
redaction, model catalog shape, `exec` allowlist, agent tool-loop states,
project load / check, project-hash staleness, skills discover/load.

## Do not copy as-is

- Step DSL (`binder <- qname(…)`) and the weak expression sub-language
- One-file-per-helper pattern (`examples/semantic-check/tools`)
- Content-addressed step cache
- Growing `builtin/list-*` / `builtin/json-*` in Haskell (belongs in
  `hwfl/*` stdlib)
- Dual language forever (`step` + script)

When asking an agent to copy from hwfi: quote the *behaviour* needed,
point at hwfi files, require the port to sit behind hwfl’s host-op /
frame APIs, and reject a second computation DSL.

hwfi’s `examples/semantic-check` is the ergonomics oracle. The hwfl port
is `examples/semantic-check/` (one entry + `lib/*` vs hwfi’s ~74 tools).
See [spec/10-acceptance.md](spec/10-acceptance.md).
