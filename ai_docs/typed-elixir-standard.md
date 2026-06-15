# Typed Elixir Coding Standard

> The canonical, **living** typed-programming standard for `repo_builder_elixir`.
> `BUILD_PROMPT.md` §3 is the frozen origin of these rules; this document is the
> editable version the team evolves. When the two disagree, **this file wins** and
> `BUILD_PROMPT.md` §3 is treated as historical context.

## Why this exists (the gradual-typing premise)

Elixir 1.20 is **gradually** typed, not statically typed. The built-in compiler
infers and checks set-theoretic types with *no annotations*, but it has **no
user-facing type signatures yet** — so it cannot check that your stated contract
matches your implementation, and it cannot validate data crossing a runtime
boundary. A real standard therefore stacks **four enforcement layers**, because no
single layer is sufficient:

| # | Layer | Tool | Catches | You write |
|---|-------|------|---------|-----------|
| 1 | Built-in set-theoretic types | `mix compile` (always on, Elixir 1.20) | Bad guards, impossible/redundant clauses, accessing a proven-absent map key, calling a fn with a disjoint type — **only when all combinations fail** | nothing |
| 2 | Contract specs | `@spec`/`@type` + `mix dialyzer` | Spec ≠ success typing, unmatched/extra/missing returns, no-local-return, opaque misuse | `@spec` on every public fn |
| 3 | Struct integrity | `typedstruct` + `@enforce_keys` | Missing required fields at runtime; struct shape drift | `field` declarations |
| 4 | Boundary validation | `TypeCheck` (`@type!` + `conforms/2`) or Ecto changeset | Untrusted external JSON before it becomes a domain struct | wire types |

> **Division of labor (memorize this).** `mix compile` is **not** equivalent to
> running Dialyzer. The compiler catches structural/guard/clause bugs without
> annotations; Dialyzer catches your *declared contract* disagreeing with reality.
> Run both — they overlap little.

---

## The rules

### 1. `@spec` on EVERY public function

- Treat a missing `@spec` on a public `def` as a **lint failure** (enforced by
  `Credo.Check.Readability.Specs`, see Enforcement).
- Prefer `{:ok, t()} | {:error, reason()}` over raising. Name `reason()`.
- Private `defp` may rely on inference, but adding specs improves Dialyzer
  precision — do it for non-trivial private functions.
- **Exemption:** a function implementing a `@callback` (carries `@impl true`) is
  already specced by the behaviour's `@callback`; it needs no repeated `@spec`,
  and its absence is **not** a lint failure (Credo's Specs check honors `@impl`).
  You may still add one for clarity.
- Each arity needs its own `@spec`.

```elixir
@spec fetch(harness()) :: {:ok, module()} | {:error, :unknown_harness}
def fetch(h), do: ...
```

### 2. Name every meaningful domain concept with `@type`

- `@type status :: :idle | :running | :error` — closed atom unions over bare `atom()`.
- Use `@opaque t :: %__MODULE__{...}` where callers must go through your API; the
  `:no_opaque` Dialyzer flag then enforces encapsulation.
- Use `@typep` for module-private aliases.

### 3. `@enforce_keys` on every struct, paired with an explicit `@type t`

- Prefer `typedstruct` (saleyn fork, `:typedstruct`) so `defstruct` +
  `@enforce_keys` + `@type t` cannot drift apart.
- A `field` without `enforce: false` is enforced and non-nil in `t`.

```elixir
use TypedStruct
typedstruct enforce: true do
  field :session_id, String.t()
  field :model, String.t(), enforce: false   # library adds `| nil`
end
```

### 4. `@behaviour` + `@callback` for every contract; `@impl true` on each implementation

- `@impl true` makes the compiler catch arity drift and typos.
- Mandatory callbacks an adapter must not implement → declare
  `@optional_callbacks` (otherwise `warnings_as_errors` makes a minimal adapter a
  hard compile error).

### 5. Precise types over broad ones

- `pos_integer()`, `non_neg_integer()`, atom unions, tagged tuples — never
  `any()`/`term()`/`map()` where a real shape is known.
- **The one deliberate exception:** harness identity is `atom()` / `String.t()`
  (open), *not* a closed `:claude | :pi` union, so adding a harness needs no core
  edit. This looseness is intentional and documented; everywhere else, be precise.

### 6. Wire type ≠ domain type

- Validate untrusted external data (harness JSON, webhook payloads) against a
  permissive **wire** type with `TypeCheck` (`@type!` + `conforms/2`) or an Ecto
  changeset **at the boundary**, then normalize into the strict internal struct.
- Never put stringly external data directly into a domain struct.
- Never `String.to_atom/1` untrusted keys — use `String.to_existing_atom/1`
  against a pre-declared atom union.
- JSONB loads back with **string keys** — model it as string-keyed, never atomize.

### 7. Compiler warnings are hard failures

- Build with `elixirc_options: [warnings_as_errors: true]` and run
  `mix test --warnings-as-errors`. New gradual-type violations block merges.

### 8. Decoder boundaries never raise

- Return `{:ok, t} | :skip | {:error, reason}` and use `Jason.decode/1` (not
  `decode!/1`). One bad line is `:skip`/`{:error, _}`, never a crash.

### 9. One nullable convention, applied uniformly

- For an optional `typedstruct` field write `field :model, String.t(), enforce: false`
  and let the library add `| nil`. Do **not** also write `String.t() | nil`
  (redundant double `| nil`). Use this form throughout.

### 10. Contexts are the only `Repo` callers

- All DB access lives behind `@spec`'d context modules. Controllers, LiveViews,
  and OTP processes never touch `Repo`/`Ecto.Query` directly. Hand-write a precise
  `@type t` per schema (the auto-generated `t()` tells Dialyzer almost nothing).

---

## Patterns

**Tagged results, not exceptions:**
```elixir
@type reason :: :unknown_harness | :at_capacity | :spawn_failed
@spec start(opts()) :: {:ok, pid()} | {:error, reason()}
```

**Closed sum types for exhaustiveness** (lets Dialyzer/compiler reason about
missing clauses): model variants as distinct typed structs unioned in a single
`@type t`. Handle each with one clause per variant.

**Boundary normalization:**
```elixir
with {:ok, raw} <- Jason.decode(line),          # wire
     {:ok, events} <- normalize(raw, ctx) do     # wire -> domain
  Enum.each(events, &dispatch/1)
else
  :skip -> :ok
  {:error, _} -> Logger.debug("unhandled line")
end
```

---

## Enforcement (the hard gate)

A merge is blocked unless **all** of these pass:

```bash
mix compile --warnings-as-errors   # layer 1 + warnings
mix test --warnings-as-errors      # behavior + warnings
mix format --check-formatted       # formatting
mix credo --strict                 # incl. Credo.Check.Readability.Specs (@spec gate)
mix dialyzer                        # layer 2 contracts, no stale ignore filters
```

- The `@spec`-on-every-public-function rule is enforced by
  `Credo.Check.Readability.Specs`, enabled in `.credo.exs`. It exempts `@impl`
  callbacks automatically (rule 1).
- Dialyzer flags live in `mix.exs` (`:underspecs`, `:unmatched_returns`,
  `:no_opaque`, `:extra_return`, `:missing_return`, …); stale ignore entries fail
  CI via `list_unused_filters: true`.
- While writing, use **Tidewave** `get_docs` for exact-version type signatures and
  `get_source_location` to read a dependency's specs instead of guessing.

## Pre-commit checklist

- [ ] Every public function has an `@spec` (or is an `@impl` callback).
- [ ] Every struct uses `typedstruct`/`@enforce_keys` with an explicit `@type t`.
- [ ] No `any()`/`term()`/`map()` where a real shape is known (harness identity excepted).
- [ ] External data validated at a wire boundary before becoming a domain struct.
- [ ] Functions return tagged tuples; decoders never raise.
- [ ] `Repo` touched only inside a context module.
- [ ] `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer` all green.

## Anti-patterns (reject in review)

- `def foo(...)` public with no `@spec` (and no `@impl`).
- `String.to_atom/1` on untrusted input.
- `Jason.decode!/1` at a streaming/line boundary.
- A domain struct populated directly from decoded JSON.
- `Repo.*` or `Ecto.Query` inside a LiveView/controller/GenServer.
- Redundant `String.t() | nil` on a `typedstruct` field already `enforce: false`.
- Broadening a type to `map()`/`any()` to silence a Dialyzer warning instead of fixing the contract.
