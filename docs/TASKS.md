# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P1)

- [ ] Streaming LLM spans (progressive span / token events)

## Next (P1–P2)

- [ ] Semantic-check deepen (layer 3 / self-check polish; optional CLI sugar)
- [ ] Skills phase D (optional) — `examples/skills/` writer; no hidden
      `skill.extract` host

## Later (P2–P3)

- [ ] Run-store interface over `.hwfl/runs`, then optional DB-backed store
- [ ] Servant HTTP API on the same run/check APIs as the CLI
- [ ] MCP client (tool provider behind existing `tool(f)` / host-op story)

## Low priority

- [ ] Concurrent host transitions in `par` — overlap blocking IO (LLM,
      `fs.read`, `exec.run`) across branches via async at host boundaries;
      coordinator owns spans/snapshots; serial under `--step`. See
      [spec/06-runtime.md](spec/06-runtime.md) §10. M5 shipped the
      cooperative pool only.
- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.) — interface
      shipped; second adapter is swap proof only
- [ ] In-language `lib/` modules (`list` / `string` / …) per [stdlib.md](stdlib.md)
- [ ] Deferred host/meta: `llm.chat_messages`, `meta.invoke`,
      `meta.list_runs`, `meta.read_spans`, `meta.read_snapshot`
- [ ] `fs.read_slice` / move / copy / remove / mkdir (P0 shipped list/edit/grep;
      `fs.write` already creates parent dirs)
- [ ] `hwfl init` / shell completions
- [ ] Complete thin `--json` CLI flag where still a stub

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07-15/16/17 completions (including P0 host gaps, coding-agent,
tool-call spans + `--debug`, lifecycle tutorial, skills A–C, try/catch runtime).
