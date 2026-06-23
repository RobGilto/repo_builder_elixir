---
description: Implement a plan in an Elixir/Phoenix/OTP repo, then pass the green gate
argument-hint: <path-to-plan>
---

# Build (Elixir)

Implement the plan at `$ARGUMENTS` into this Elixir/Phoenix/OTP codebase.

Honor the typed style guide: an `@spec` on every public function (`@impl true`
callbacks exempt), `@type`/`typedstruct`/`@enforce_keys` for domain data, precise types
over `any()`/`map()`, `{:ok, t()} | {:error, reason()}` over raising. Keep DB access
behind `@spec`'d context modules — LiveViews/controllers/OTP processes never touch
`Repo`/`Ecto.Query` directly.

Validation gate (must pass before you finish):

- `mix compile --warnings-as-errors`
- `mix format` then `mix format --check-formatted`
- `mix credo --strict`
- `mix test --warnings-as-errors`
- `mix dialyzer` (best-effort; never weaken existing ignore filters)
