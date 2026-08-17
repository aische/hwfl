# `obs` — observability

Does not checkpoint the run. Does not need an effect in `effects:`.

## `obs.log`

**Signature:** `{ level: String, message: String, fields?: record | Json } -> ()`

Also `obs.log(level, message)` with two positional strings.

```hwfl
obs.log(level = "info", message = "started", fields = { n = 1 })
obs.log("info", "started")
```

## `obs.span`

**Signature:** `(name: String, fun () -> a) -> a`

The result is the thunk body type. Curried or two-argument:

```hwfl
obs.span("cluster")(fun () =>
  { n = 3, label = "ok" }
)

obs.span("cluster", fun () =>
  { n = 3, label = "ok" }
)
```

Host ops already open their own spans. Use `obs.span` to group pure or
mixed work under a name you can filter in `hwfl show --filter`.

## Inspecting

```bash
hwfl show <workspace>
hwfl show <workspace> --tree
hwfl show <workspace> --spans --filter llm
hwfl run … --debug          # live span open/close on stderr
hwfl run … -v               # tree after the run
hwfl run … --cost           # running LLM spend prefix
```
