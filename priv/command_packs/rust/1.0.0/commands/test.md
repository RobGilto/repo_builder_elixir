---
description: Run the Rust (cargo) test + clippy gate and report
argument-hint: [filter]
---

# Test (Rust)

Run the gate with cargo, reporting each command:

1. `cargo fmt --check`
2. `cargo clippy -- -D warnings`
3. `cargo test` (append `$ARGUMENTS` to filter test names when provided)

On failure, surface the failing output verbatim and propose the smallest fix.
