# CLI

Executable: `hwfl`. After install, the commands below are as written.
From a source checkout: `cabal run hwfl -- <command> …`.

Dash-prefixed paths: `hwfl check -- -odd.md`.

## Commands

| Command | Purpose |
|---------|---------|
| `hwfl init [dir]` | Scaffold `project.json` + `workflows/main.md` (refuses to overwrite) |
| `hwfl check <project\|module.md> [--json]` | Parse, types, effects, graph. No host effects |
| `hwfl run <project\|module.md> [options]` | Check (unless `--no-check`) + execute entrypoint |
| `hwfl step <workspace> [run-id]` | One saved host call or human gate, then pause |
| `hwfl resume <workspace> [run-id]` | Continue until end / pause / fail |
| `hwfl approve <workspace> [run-id] --yes\|--no` | Resolve `confirm` |
| `hwfl choose <workspace> [run-id] --select <option>` | Resolve `choice` |
| `hwfl reply <workspace> [run-id] --text <string>` | Resolve `human.ask` |
| `hwfl extend <workspace> [run-id] --rounds N` | Bump agent `max_rounds` and continue |
| `hwfl show <workspace> [run-id] [flags]` | Status / spans / snapshot |
| `hwfl version` | `hwfl 0.1.0.0` |
| `hwfl parse <module.md>` | Print the parsed module (debugging) |

`check` / `run` take a **project directory or module path**.
`step` / `resume` / `approve` / `choose` / `reply` / `extend` / `show`
take the **workspace** (where `.hwfl/runs/` lives). The run id may be
omitted or the token `latest` — that picks the newest `started_at` in
the workspace. An explicit id still wins.

## `run` options

| Flag | Meaning |
|------|---------|
| `--workspace <dir>` | Sandbox + run store. Default: the project directory when the target is a project |
| `--input k=v` | Repeatable. Overrides `--example` keys |
| `--example <name>` | Frontmatter `examples:` entry (typed at check) |
| `--llm-provider mock\|simple` | Default `simple` |
| `--model-catalog <path>` | Default `model-catalog.json` |
| `--no-check` | Skip check (not recommended) |
| `--step` | One saved host call or human gate, then pause |
| `-v` / `--verbose` | Span tree on stderr after the run |
| `--debug` | Live span open/close (implies verbose) |
| `--cost` | Prefix host lines with running LLM spend |
| `--dump` | Write raw LLM request/response JSON under `./dumps` |
| `--json` | Machine-readable diagnostics on failure |
| `--interactive` | TTY only: prompt for human gates in-process. Not with `--json` |

`--input` coercion: `true` / `false` → `Bool`; all-digits (optional
leading `-`) → `Int`; otherwise `String` (including paths). Complex
values belong in `--example` YAML/JSON, not `--input`.

## `show` flags

| Flag | Meaning |
|------|---------|
| (default) / `--tree` | Summary + nested spans |
| `--spans` | Flat span lines |
| `--spans --filter PREFIX` | Name prefix (`llm`, `fs`, …) |
| `--snapshot` | Saved run state (secrets stripped) |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed successfully |
| 1 | Check or runtime failure |
| 2 | Usage / bad flags |
| 3 | Paused (confirm, choice, ask, `--step`, agent extend, exec confirm) |
| 4 | Stale project hash — resume refused after code/frontmatter change |

Stderr includes `hwfl run: run_id=<id>` and pause hints such as
`awaiting confirm: …`.

## Hello loop

Full walkthrough: [tutorial](tutorial.md).

```bash
hwfl init /tmp/hwfl-hello
hwfl check /tmp/hwfl-hello
hwfl run /tmp/hwfl-hello --llm-provider mock
# exit 3 — omit the run id (or pass latest) for the next commands
hwfl approve /tmp/hwfl-hello --yes
hwfl show /tmp/hwfl-hello
```

## Persistence

```text
<workspace>/.hwfl/runs/<run-id>/
  meta.json
  snapshot.json
  spans.jsonl
  …
```

`resume` continues a paused or interrupted run. `step` / `run --step`
advances one saved host call or human gate, then pauses.

## Providers

`mock` — no network, no catalog, deterministic stubs.  
`simple` — needs catalog + credentials (`.env` / process env). `--dump`
writes raw request/response JSON for debugging.
