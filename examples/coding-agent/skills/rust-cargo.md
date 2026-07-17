---
name: skills/rust-cargo
skill:
  kind: instruction
  summary: "Minimal Cargo library/binary and cargo test verify"
  tags: [rust, cargo]
---

# Rust / Cargo

Prefer a tiny crate:

- `Cargo.toml` — package name + edition 2021
- `src/lib.rs` — e.g. `pub fn add(a: i32, b: i32) -> i32`
- unit tests in the same file or `tests/add.rs`

Verify:

```bash
cargo test
```

Rules:

- No extra crates unless the prompt requires them.
- On failure, edit and re-run `cargo test`.
