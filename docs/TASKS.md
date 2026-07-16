# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P0)

- [ ] Runtime `exec.run` (check prelude already types it; wire host op +
      allowlist / confirm policy from `project.json`)
- [ ] FS host ops for agents: at least `fs.list`, `fs.edit`, `fs.grep`
      (then `read_slice` / move / copy / remove / mkdir as needed)
- [ ] Language reference: one card — keywords, builtin types, prelude +
      host ops with type signatures (brief or empty descriptions OK)

## Next (P1)

- [ ] Real coding-agent example (sandbox edit / test loop using exec + FS)
- [ ] Tutorial: module → `check` → `run` → `resume` → `show`
- [ ] CLI `--debug` (and complete `-v` / `--json` where thin)
- [ ] Streaming LLM spans (progressive span events; already STATUS #1 before
      reorder — still wanted, not a capability unlock)

## Later (P2–P3)

- [ ] Semantic-check deepen (layer 3 / self-check polish; optional CLI sugar)
- [ ] Skills — full plan: [skills-plan.md](skills-plan.md) (catalog +
      `skill.discover` / `skill.load`, agent mid-loop load + resume)
- [ ] Run-store interface over `.hwfl/runs`, then optional DB-backed store
- [ ] Servant HTTP API on the same run/check APIs as the CLI
- [ ] MCP client (tool provider behind existing `tool(f)` / host-op story)

## Low priority

- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.) — interface
      shipped; second adapter is swap proof only
- [ ] In-language `lib/` modules (`list` / `string` / …) per [stdlib.md](stdlib.md)
- [ ] Deferred host/meta: `llm.chat_messages`, `meta.invoke`,
      `meta.list_runs`, `meta.read_spans`, `meta.read_snapshot`
- [ ] `try` / `catch` runtime (AST exists; eval/check unsupported)
- [ ] `hwfl init` / shell completions

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07-15/16 completions.
