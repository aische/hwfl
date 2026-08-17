# `human` — operator gates

**Effect:** `Human`. Durable pause (CLI exit `3` unless `--interactive`).

`confirm { … }` is `human.confirm`. `choice { … }` is `human.choice`.
`human.ask` has no keyword sugar.

## `human.confirm`

**Signature:** `{ title: String, detail?: String } -> Bool`

```hwfl
let ok = confirm {
  title = "Accept this greeting?",
  detail = greeting
}
```

Resolve: `hwfl approve <workspace> <run-id> --yes` or `--no`.

## `human.choice`

**Signature:** `{ title: String, options: List<String>, detail?: String } -> String`

Result is the selected option string.

```hwfl
let env = choice {
  title = "Deploy target?",
  detail = "Pick where to promote the build.",
  options = ["staging", "prod", "abort"]
}
```

Resolve: `hwfl choose <workspace> <run-id> --select staging`.

## `human.ask`

**Signature:** `{ prompt: String, detail?: String } -> String`

```hwfl
let user = human.ask({
  prompt = "You>",
  detail = "Type a message, or /quit to end."
})
```

Resolve: `hwfl reply <workspace> <run-id> --text "hello"`.

`detail` is what UIs / `--interactive` can show without reading the
snapshot (for example the previous assistant reply).

## Interactive and `par`

On a TTY, `hwfl run … --interactive` prompts on stdin and resolves gates
in-process (no exit `3` between turns). Incompatible with `--json`.

Inside `par`, a human gate **freezes the pool**. Completed iterations are
not re-run on resume.
