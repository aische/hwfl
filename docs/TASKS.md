# Tasks

Active work only. Archive completed sections to `log/archive/` weekly.

## Now (P1) — lab loop + exemplars

High #1–#5 runtime integrity done (nested snapshot, `meta.invoke`
sandbox, crash-safe store + run IDs, checker holes, submit schema +
tool-name uniquify).

### Credible coding-agent exemplar

Target shape (extend `examples/coding-agent` / chat; language owns the
loop, LLMs fill holes). **Serial** task iteration — not `par` / worktrees.

```text
chat (human.ask + history)
  └─ tool: coding_session(prompt)     # FrInvoke → workflows/coding
        ├─ plan → List<Task>          # llm.object (typed)
        └─ for task in tasks          # workflow for / recursive fun
              ├─ do_task(task)        # agent_object or focused workflow
              └─ verify(task)         # FrInvoke workflow / exec wrapper
                    └─ fail → retry same task / replan rest / stop
```

- [ ] **Chat layer** — multi-turn `human.ask` loop; chat does not own
      `fs.write`; delegates via a coding-session tool
- [ ] **Coding session as FrInvoke tool** — typed `{ summary, ok, … }`;
      same run/workspace; nested spans under the chat tool call
- [ ] **Workflow-owned task loop** — plan is a typed value; `for` (or
      equivalent) drives implement → verify per task (not “agent remembers
      a checklist” alone)
- [ ] **`workflows/gather_context`** — Read-only context pre-pass (list /
      find / grep / read + rank under a token budget); agent tool via
      `FrInvoke` / `tool(wrap)`
- [ ] **`workflows/verify`** — run allowlisted check; return
      `{ exit, stdout, stderr, ok }`; called after each task
- [ ] Dogfood: resume mid-task / mid-verify; effect check on callees;
      keep instruction `skills/*`; avoid nesting agent-in-agent by default

**Skills policy (open — decide at implement / lab A-B):**

- **(A) Agent-driven** — planner/coder advertise `skill.discover` /
  `skill.load`; each agent loads if it wants (closest to today’s
  coding-agent). Default for the first cut.
- **(B) Workflow-driven** — session module calls discover/load *outside*
  the agent and injects instruction `content` into `system` for plan /
  do_task; agents have no `skill.*` tools.

Either way: verifier stays a non-agent workflow (no skill tools); one
skill file can still be the stack source of truth. Both variants are
fine later as compare/evolve genomes — not required as dual product
surface.

Out of this exemplar: parallel sub-agents, commit-per-tool-round,
worktrees, MCP/git/terminals (Tier A only when this bites), embeddings.

## Next (P1–P2) — agent substrate

Prefer MCP / workflow modules over growing the host-op set.

- [ ] MCP client (tool provider behind `tool(f)` / host-op story)
- [ ] Git (read-heavy host ops or MCP) — status / diff / log
- [ ] Persistent terminal sessions (`term.*` or MCP) vs one-shot
      `exec.run`

## Later (P2–P3)

### Observability

- [ ] Opt-in LangSmith-style LLM transcripts — durable messages in/out
      keyed by `span_id` (`transcripts.jsonl` or `payloads/`); spans stay
      the thin index. CLI `--trace` / run option; redact + size caps.
      See [spec/07-observability.md](spec/07-observability.md) §10.

### Research / optional

- [ ] Semantic-check S4 / S6 — parked; see
      [semantic-check-plan.md](semantic-check-plan.md); optional fitness
      filter for lab candidates
- [ ] Optional: lab fitness sum `cost_micros` (spans already counted)
- [ ] Skills phase D (optional) — `examples/skills/` writer; no hidden
      `skill.extract` host
- [ ] Optional: omit / `latest` run-id for approve / choose / reply / show
      (resolve from workspace run store by status + recency)

### Parallelism

- [ ] Concurrent host transitions in `par` — overlap blocking IO across
      branches; **or** run lab candidates as external parallel processes.
      See [spec/06-runtime.md](spec/06-runtime.md) §10.
- [ ] Multi-process run-store locking (only if external parallel lab
      processes share a run dir)

## Low priority

- [ ] Alternate `LlmProvider` (OpenAI/Anthropic SDK, etc.)
- [ ] In-language `lib/` modules per [stdlib.md](stdlib.md)
- [ ] `hwfl init` / shell completions
- [ ] Typed validation of example values vs `TypeExpr`; CLI `--example`

## Future / nice-to-have (coding-agent Tier B)

Delay until a measured lab / coding-agent gap.

- [ ] Codebase index (embeddings and/or tree-sitter + ripgrep)
- [ ] LSP bridge; project rules/hooks skills; auto context assembly;
      multi-model routing

### Explicitly out of scope (Tier C / product)

IDE surface, inline diff UX, browser / multimodal — control-plane or
other product; hwfl stays the orchestration kernel. Control plane /
Postgres live in **hwfl-server**, not here. See [idea.md](idea.md).

## Done

See [log/archive/tasks-2026-07.md](log/archive/tasks-2026-07.md) for M0–M9
and 2026-07 completions (P0, coding-agent, skills A–C, semantic-check
A+B / S1–S3 / S5, `fs.patch`, lab spine, E11, coding-agent chat, compare
mutate / next-gen, evolve-agent E23, `obs.log` non-snapshotting,
soft-land `max_rounds`, turing-machine exemplar + zero-arg funs,
nested snapshot outer-only persist (#1), `meta.invoke` sandbox (#2),
crash-safe store + run IDs (#3), checker holes for match/confirm/choice
(#4), submit schema validation + tool-name uniquify (#5)).
