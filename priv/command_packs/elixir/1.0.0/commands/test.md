---
description: Run the Elixir green gate (compile/format/credo/test) and report
argument-hint: [filter]
---

# Test (Elixir)

Run the project-wide green gate and report each command's status:

1. `mix compile --warnings-as-errors`
2. `mix format --check-formatted`
3. `mix credo --strict`
4. `mix test --warnings-as-errors` (append `$ARGUMENTS` to scope to a file/line)

On failure, surface the failing output verbatim and propose the smallest fix. The
Postgres test DB is created by `mix test`; do not start/stop the cluster.
