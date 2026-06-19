# BUILD_PROMPT.md — Build `repo_builder_elixir`: a harness-agnostic AI agent orchestration platform

> **You are the implementing agent.** Build the application described below from scratch in a brand-new Elixir repository. Follow every hard decision in this document exactly. When a version is given, use that exact version — never substitute a version you remember. When research could not verify a version, the word **verify** appears and you must check hex.pm before pinning. Write idiomatic, strictly-typed Elixir. Do not deviate from the architecture without flagging it.

---

## 1. Mission and Non-Goals

### Mission

Build a **harness-agnostic AI agent orchestration platform** in Elixir/Phoenix/OTP. It generalizes the "deterministic orchestration of non-deterministic AI agents" pattern (the TAC / ADW idea): humans/cron/webhooks compose **deterministic** workflows ("ADWs" — e.g. `plan -> build -> review -> fix`) whose **step order and branching are fixed**, but whose **intelligent work inside each step is delegated to an external AI agent harness**. The platform provides:

- **CRUD of agents** (durable definitions: name, harness, provider, model, config).
- **Composable chained agentic workflows (ADWs)**: deterministic state machines whose steps delegate execution to a harness.
- **Real-time observability**: a Phoenix LiveView dashboard showing live logs, tool calls, cost/usage, and status for every live agent and workflow, swimlane-style.

The defining constraint: the platform is **NOT locked to Claude Code**. It must drive **multiple harnesses/providers** for both the orchestrator agent and the worker agents, through a **swappable service layer**. The two initial harnesses are the **Claude Code CLI** and the **pi CLI**. Adding a third harness must be a matter of writing **one adapter module** plus a small, well-defined registry/config edit (see §10 for exactly what "one module" does and does not include).

### Non-Goals (do not do these)

1. **No Ash framework.** Rationale: the hard part here is OS-process supervision + protocol adapters + PubSub fan-out, not declarative database modeling. Ash would impose a second large learning curve and a resource DSL for no gain on the actual hard problem. Use plain Phoenix + OTP + Ecto with disciplined, `@spec`'d contexts.
2. **Do NOT reimplement a harness or its SDK.** Each harness is an **external CLI process** driven as a supervised child. You normalize its output; you never re-implement its agent loop.
3. **This is not a generic CRUD app.** CRUD exists only to persist agent/workflow definitions and observability records. The product is the live orchestration + observability runtime.

---

## 2. Tech Stack (exact versions from verified research)

Pin these. Each row cites the package's hex/doc URL. Where a version is marked **verify**, confirm on hex.pm before pinning — do not invent.

| Concern | Package | Exact version / pin | Notes & citation |
|---|---|---|---|
| Language | Elixir | **1.20.1** (released 2026-06-09) — pin `elixir: "~> 1.20"` | First milestone of built-in gradual set-theoretic types: full inference + gradual checking, no annotations required. https://hexdocs.pm/elixir/changelog.html |
| Runtime | Erlang/OTP | **28.x** recommended (install default pair is `elixir@1.20.1 + otp@28.4`); **29.0.2** also fully supported; minimum OTP 27 | Elixir 1.20 supports OTP 27–29. https://github.com/erlang/otp/releases |
| Web framework | phoenix | **1.8.8** (2026-06-10) — `{:phoenix, "~> 1.8.8"}` | LiveView on by default; bandit default adapter. https://hex.pm/packages/phoenix |
| Realtime PubSub | phoenix_pubsub | **2.2.0** (2025-10-22) — `{:phoenix_pubsub, "~> 2.2"}` (usually transitive) | PG2 adapter, no external infra. https://hex.pm/packages/phoenix_pubsub |
| LiveView UI | phoenix_live_view | **1.2.1** (2026-06-12) — `{:phoenix_live_view, "~> 1.2"}` | Streams, `assign_async`/`start_async`, `AsyncResult`. https://hex.pm/packages/phoenix_live_view |
| ORM core | ecto | **3.14.0** (2026-05-19) — transitive via ecto_sql | Ecto.Schema, Changeset, Enum, embedded_schema. https://hex.pm/packages/ecto |
| SQL + migrations | ecto_sql | **3.14.0** (2026-05-19) — `{:ecto_sql, "~> 3.14"}` | Carries the Postgres adapter + `mix ecto.*`. https://hex.pm/packages/ecto_sql |
| Postgres driver | postgrex | **0.22.2** (2026-05-12) — `{:postgrex, ">= 0.0.0"}` | Latest **stable**; the `1.0.0-rc.*` builds are RCs **and retired** — do NOT use. https://hex.pm/packages/postgrex |
| **OS-process driver** | **erlexec** (recommended) | **2.3.4** (2026-06-12) — `{:erlexec, "~> 2.0"}` (verify lockfile lands on 2.3.4; 2.3.0–2.3.3 are **retired**) | **Chosen primitive** — see §6 for the rationale. https://hex.pm/packages/erlexec |
| OS-process containment (alt.) | muontrap | **1.8.0** (2026-05-06) — `{:muontrap, "~> 1.8"}` | Strongest anti-orphan containment (cgroups) but **not for interactive stdin** children. Keep as an option for the fire-and-forget containment path and the hard-SIGKILL subtree-kill guarantee (§6). https://hex.pm/packages/muontrap |
| Durable jobs / cron / triggers | oban | **2.23.0** (2026-05-27) — `{:oban, "~> 2.23"}` | OSS: workers, queues, Cron plugin, unique jobs, telemetry. Requires PG 14+. https://hex.pm/packages/oban |
| Typed structs | typedstruct (saleyn fork) | **0.5.4** — `{:typedstruct, "~> 0.5", runtime: false}` | **Use the saleyn fork** (package name `:typedstruct`, no underscore). OTP-26+ compatible. The original `:typed_struct` (0.3.0, 2022) is unmaintained — do not use. https://hex.pm/packages/typedstruct |
| Runtime boundary validation | type_check (TypeCheck) | **0.13.7** (2024-10-21) — `{:type_check, "~> 0.13.7"}` | Runtime conformance of untrusted harness JSON at the boundary. https://hex.pm/packages/type_check |
| Behaviour mocking (test) | mox | **1.2.0** (2024-08-14) — `{:mox, "~> 1.2", only: :test}` | Concurrency-safe behaviour mocks. https://hex.pm/packages/mox |
| Static analysis | dialyxir | **1.4.7** (2025-11-06) — `{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}` | Wraps Dialyzer; still required for `@spec` contract checking. https://hex.pm/packages/dialyxir |
| JSON | jason | **verify** latest on hex.pm — `{:jason, "~> 1.4"}` | Not version-verified in research; Phoenix pulls it in transitively and will satisfy `~> 1.4`. Pin the latest 1.4.x you confirm. https://hex.pm/packages/jason |
| Lint (optional, recommended) | credo | **verify** latest on hex.pm — `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` | Not version-verified in research (the `~> 1.7` range comes from an example, not a latest-version lookup). Confirm the latest 1.7.x before pinning. Enforce "every public fn has an `@spec`" via review/Credo. https://hex.pm/packages/credo |
| Timezone DB (only if non-UTC cron) | tz | **verify** — `{:tz, "~> VERSION"}` | No version is backed by research. Add `tz` at the latest version from hex.pm **only if** Oban cron uses a non-UTC `:timezone`; otherwise omit it entirely. https://hex.pm/packages/tz |

**OTP/Elixir pairing rule:** Elixir 1.20 requires OTP 27+ and is validated only through OTP 29. Pin OTP 28.x for maximum battle-testing (the install-script default), or 29.x. Do not assume OTP 30 compatibility.

---

## 3. Typed Style Guide (a first-class requirement)

Typed programming is non-negotiable. Two layers enforce it: (a) the **always-on built-in compiler** (Elixir 1.20 gradual set-theoretic types — catches structural/guard/clause/map-key bugs at compile time, with no annotations) and (b) **`@spec`/`@type` + Dialyzer** (catches spec-vs-implementation contract violations the compiler cannot yet see, because the built-in system has no user-facing type signatures yet). Run both — they overlap little.

### Rules

1. **`@spec` on EVERY public function.** Prefer `{:ok, t()} | {:error, reason()}` over raising. Treat a missing `@spec` on a public `def` as a lint failure. Private `defp` may rely on inference, but adding specs improves Dialyzer precision. **Exemption:** functions that implement a `@callback` (carry `@impl true`) are already specced by the behaviour's `@callback` and need not repeat an `@spec`; you may still add one for clarity, but its absence on a callback implementation is **not** a lint failure.
2. **`@type` / `@typep` / `@opaque` for all domain data.** Name every meaningful domain concept (`@type status :: :idle | :running | :error`). Use `@opaque t :: %__MODULE__{...}` where callers must go through your API; `:no_opaque` then enforces encapsulation.
3. **`@enforce_keys` on every struct** (a runtime guarantee, NOT a type check) paired with an explicit `@type t :: %__MODULE__{...}` listing each field's concrete type. Prefer `typedstruct` (0.5.4) so `defstruct` + `@enforce_keys` + `@type t` cannot drift.
4. **`@behaviour` with `@callback` specs** for the Harness contract and any other behaviour. Every implementation puts `@impl true` on each callback so the compiler catches arity drift/typos.
5. **Precise types over broad ones.** `pos_integer()`, `non_neg_integer()`, atom unions, tagged tuples — never `any()`/`term()`/`map()` where a real shape is known. The set-theoretic compiler narrows aggressively from guards/patterns; precise inputs find more bugs. **Deliberate exception:** the harness-identity type is `atom()` (open) rather than a closed `:claude | :pi` union, because adding a third harness must not require editing a core union (§10). This is the single intentional looseness; everywhere else use precise unions.
6. **Wire type ≠ domain type.** Validate untrusted harness JSON against a permissive **wire** type with TypeCheck (`@type!` + `conforms/2`) or an Ecto changeset at the boundary, then normalize into the strict internal struct. Never put stringly external data directly into a domain struct. Never `String.to_atom/1` untrusted keys — use `String.to_existing_atom/1` with a pre-declared atom union.
7. **Compiler warnings are hard failures.** Build with `--warnings-as-errors` (set `elixirc_options: [warnings_as_errors: true]`) and run `mix test --warnings-as-errors` in CI so the new gradual type violations block merges. **Consequence:** a behaviour with mandatory `@callback`s that an adapter does not implement becomes a hard compile error — so optional callbacks MUST be declared `@optional_callbacks` (see §4.2).
8. **Decoder boundary returns `{:ok, t} | :skip | {:error, reason}` and never raises** on one bad JSONL line. Use `Jason.decode/1` (not `decode!/1`) at the line boundary.
9. **Pick one nullable-field convention and apply it uniformly.** For a `typedstruct` optional field, write `field :model, String.t(), enforce: false` and let the library add `| nil` — do **not** also write `String.t() | nil` (that yields a redundant double `| nil`). Equivalently `field :model, String.t() | nil, default: nil`. Choose the first form throughout this codebase.

### `mix.exs` `:dialyzer` config

```elixir
defp dialyzer do
  [
    plt_file: {:no_warn, "priv/plts/project.plt"},   # {:no_warn,...} silences the local deprecation
    plt_core_path: "priv/plts/core.plt",
    plt_add_apps: [:mix, :ex_unit],
    flags: [
      :error_handling,
      :underspecs,
      :unmatched_returns,
      :no_opaque,
      :extra_return,
      :missing_return
    ],
    ignore_warnings: ".dialyzer_ignore.exs",
    list_unused_filters: true,   # fail CI when an ignore entry goes stale
    format: "github"
  ]
end
```

`.gitignore` must include `priv/plts/*.plt` and `priv/plts/*.plt.hash`. Generate ignore entries with `mix dialyzer --format ignore_file_strict`. Keep `:unknown` (dialyxir default) on.

### Example typed function

```elixir
defmodule RepoBuilder.Agents.Agent do
  use RepoBuilder.Schema             # centralizes binary_id + utc timestamps (see §8)
  import Ecto.Changeset

  @type provider :: :anthropic | :openai | :local
  @type status :: :idle | :running | :error
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          harness: String.t() | nil,        # validated against the registry, NOT a closed Enum (§10)
          provider: provider() | nil,
          status: status(),
          config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :harness, :string                  # open: any registered harness key (§10)
    field :provider, Ecto.Enum, values: [:anthropic, :openai, :local]
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :config, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(agent, params) do
    agent
    |> cast(params, [:name, :harness, :provider, :status, :config])
    |> validate_required([:name, :harness, :provider])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:harness, RepoBuilder.Harness.Registry.known(),
         message: "is not a registered harness")
    |> unique_constraint(:name)
  end
end
```

> **Why `harness` is a validated string, not `Ecto.Enum`.** A closed `Ecto.Enum[:claude, :pi]` would make adding a third harness a core data-model edit (and casting a `:cursor` agent would raise). The harness identity is intentionally **open** (§5, rule 5): store it as a `:string`, and enforce membership at the changeset boundary via `validate_inclusion/3` against `RepoBuilder.Harness.Registry.known/0` (the live registry keys). This keeps "add a harness = adapter + config" true while still rejecting unknown values at write time.

**Division of labor reminder:** the compiler catches wrong guards, impossible/redundant clauses, accessing a proven-absent map key, and calling a stdlib/dep fn with a disjoint type — without annotations, but only when *all* combinations fail. Dialyzer catches your `@spec` disagreeing with the success typing, unmatched returns, no-local-return functions, opaque misuse. `mix compile` alone is **not** equivalent to running Dialyzer.

---

## 4. The Canonical Harness Event Contract (the keystone)

Every adapter normalizes its harness's raw JSON stream into **one shared, closed set of typed events**. The orchestrator, persistence, and UI speak **only** the canonical events — they are harness-blind.

### 4.1 Canonical event variants (typed structs)

Model the contract as a **closed sum type** so Dialyzer can reason about exhaustiveness. Each variant is a `typedstruct` carrying a `:harness` provenance atom and a `raw: map()` escape hatch so nothing in the wire frame is lost.

> **`harness()` is `atom()`, not a closed union.** Every event carries `harness: atom()` (the registry key), NOT `:claude | :pi`. This is the one deliberate looseness (§3 rule 5, §5, §10): a `:cursor` event must be representable without editing a core union. The trade-off — Dialyzer cannot narrow on the harness value — is accepted in exchange for true zero-core-change extensibility.

> **`raw: map()` redaction.** The `raw` escape-hatch retains the full wire frame, which can include prompts, tool arguments, or provider responses that contain secrets. `raw` is persisted to `agent_logs` JSONB (§8). **Before persisting**, pass each event through `RepoBuilder.Harness.Redact.scrub/1`, which (a) drops/masks known credential keys (`api_key`, `authorization`, `token`, `ANTHROPIC_API_KEY`, provider keys) anywhere in `raw`, and (b) truncates oversized blobs. The in-flight (PubSub) event keeps full `raw` for the live UI; only the persisted copy is scrubbed. Document this so reviewers do not read the unredacted `raw` map as a data-handling gap.

```elixir
defmodule RepoBuilder.Harness.Event do
  @moduledoc "Canonical, harness-blind event sum type. All adapters normalize into these."

  @typedoc "Open harness-identity (a registry key); NOT a closed union — adding a harness adds no core type edit (§10)."
  @type harness :: atom()

  @type t ::
          __MODULE__.SessionStarted.t()
          | __MODULE__.TextDelta.t()
          | __MODULE__.ToolCall.t()
          | __MODULE__.ToolResult.t()
          | __MODULE__.Usage.t()
          | __MODULE__.Status.t()
          | __MODULE__.Done.t()
          | __MODULE__.Error.t()

  defmodule SessionStarted do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :session_started, default: :session_started
      field :harness, RepoBuilder.Harness.Event.harness()
      field :session_id, String.t()
      field :model, String.t(), enforce: false
      field :tools, [String.t()], enforce: false
      field :raw, map(), default: %{}
    end
  end

  defmodule TextDelta do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :text_delta, default: :text_delta
      field :harness, RepoBuilder.Harness.Event.harness()
      field :text, String.t()
      field :thinking?, boolean(), default: false   # route reasoning to a thinking pane
      field :raw, map(), default: %{}
    end
  end

  defmodule ToolCall do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :tool_call, default: :tool_call
      field :harness, RepoBuilder.Harness.Event.harness()
      field :id, String.t(), enforce: false
      field :name, String.t()
      field :input, map(), default: %{}
      field :raw, map(), default: %{}
    end
  end

  defmodule ToolResult do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :tool_result, default: :tool_result
      field :harness, RepoBuilder.Harness.Event.harness()
      field :id, String.t(), enforce: false
      field :is_error, boolean(), default: false
      field :content, term()
      field :raw, map(), default: %{}
    end
  end

  defmodule Usage do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :usage, default: :usage
      field :harness, RepoBuilder.Harness.Event.harness()
      field :input_tokens, non_neg_integer()
      field :output_tokens, non_neg_integer()
      field :cache_read, non_neg_integer(), enforce: false
      field :cache_creation, non_neg_integer(), enforce: false
      field :cost_usd, float(), enforce: false   # nil = unknown/unpriced; 0.0 = priced at zero
      field :raw, map(), default: %{}
    end
  end

  defmodule Status do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :status, default: :status
      field :harness, RepoBuilder.Harness.Event.harness()
      field :kind, :retry | :init_detail | :plugin_install | :rate_limit
      field :attempt, integer(), enforce: false
      field :detail, map(), default: %{}
      field :raw, map(), default: %{}
    end
  end

  defmodule Done do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :done, default: :done
      field :harness, RepoBuilder.Harness.Event.harness()
      field :ok, boolean()
      field :reason,
            :success | :clean_exit | :agent_end | :error_during_execution
            | :max_turns | :max_budget | :max_structured_output_retries | :idle_timeout
      field :duration_ms, integer(), enforce: false
      field :num_turns, integer(), enforce: false
      field :final_text, String.t(), enforce: false
      field :usage, map(), enforce: false
      field :cost_usd, float(), enforce: false
      field :raw, map(), default: %{}
    end
  end

  defmodule Error do
    use TypedStruct
    typedstruct enforce: true do
      field :type, :error, default: :error
      field :harness, RepoBuilder.Harness.Event.harness()
      field :message, String.t()
      field :reason, :provider_error | :auto_retry_exhausted | :idle_timeout | :spawn_failed | :unknown,
            default: :unknown
      field :retryable, boolean(), default: false
      field :status, integer(), enforce: false
      field :raw, map(), default: %{}
    end
  end
end
```

**Semantic rules baked into the contract (do not break these):**

- `:session_started` is emitted **once** at stream open.
- `:text_delta` carries incremental OR finalized assistant text; `thinking?: true` for reasoning content.
- `cost_usd` is `nil` when **unknown/unpriced** and `0.0` only when **priced at zero**. Do **not** default pi cost to `0.0`. `cost_usd` is `float()` in the canonical event; the **float→Decimal conversion boundary is the persistence layer** (§8): when rolling per-event float costs into the `:decimal` columns (`agent_logs.usage`, `workflow_runs.total_cost_usd`) use `Decimal.from_float/1`, and treat `nil` (unpriced) distinctly from `0.0` (priced-at-zero) — store `nil` as SQL `NULL`, not `0`.
- `:done` is the terminal **success** marker; `:error` is the terminal/fatal **failure** marker. `:done.ok` reflects the harness's `is_error`, **not** merely its subtype.
- **Idle-timeout is a terminal outcome with a stable shape.** When the session runtime's idle timer fires (§6) it interrupts the child and emits **`%Error{reason: :idle_timeout, retryable: true}`**. If the runtime instead observes a clean exit with output but no `agent_end`, it emits `%Done{ok: true, reason: :clean_exit}`. The heuristic: a clean process exit (code 0) with prior real output ⇒ `:clean_exit` (success); an idle timer firing with the child still running ⇒ kill + `:idle_timeout` (failure, retryable). `:done.reason` therefore includes `:idle_timeout` only for the (rare) case where output had completed but the process lingered and the timer reclaimed it as a non-error stop — prefer `%Error{reason: :idle_timeout}` in the live/hung case.

### 4.2 The Harness behaviours (mandatory adapter + optional custom spawn)

There are **two** behaviours so that the "add a harness = one module" promise holds under warnings-as-errors (§3 rule 7). A minimal adapter implements only the **mandatory** behaviour (`command/2` + `normalize/2`); the generic erlexec session runtime (§6) drives it. An adapter that needs bespoke spawning *additionally* implements the **optional** `CustomSpawn` behaviour.

```elixir
defmodule RepoBuilder.Harness do
  @moduledoc """
  MANDATORY harness behaviour. A minimal adapter implements ONLY these two
  callbacks; the generic session runtime (§6) provides spawning, line framing,
  stdin, interrupt, and termination uniformly. Everything downstream of
  `normalize/2` is harness-blind.
  """
  alias RepoBuilder.Harness.Event

  @type start_opts :: %{
          required(:prompt) => String.t(),
          required(:model) => String.t() | nil,
          required(:cwd) => Path.t(),
          required(:sink) => pid(),       # process that receives canonical events / raw chunks
          optional(:config) => map(),
          optional(:secrets) => map()     # credentials resolved at runtime (§6); NEVER logged
        }

  @typedoc "Adapter-private per-session context returned by command/2 and threaded into normalize/2."
  @type session_ctx :: term()

  @doc """
  Build the argv + env to spawn this harness in streaming-JSON mode, plus an
  adapter-private `session_ctx` threaded back into `normalize/2`. Pure; no side effects.
  Credentials come from `opts.secrets` and are placed in `env` — never embedded in argv,
  never logged.
  """
  @callback command(start_opts()) ::
              {exe :: String.t(), args :: [String.t()],
               env :: [{String.t(), String.t()}], session_ctx()}

  @doc """
  Normalize ONE raw decoded JSONL frame into zero-or-more canonical events.
  Must NEVER raise on a malformed/unknown frame; return `:skip` instead.
  """
  @callback normalize(raw :: map(), session_ctx()) ::
              {:ok, [Event.t()]} | :skip | {:error, term()}
end

defmodule RepoBuilder.Harness.CustomSpawn do
  @moduledoc """
  OPTIONAL behaviour. Implement ONLY if an adapter must spawn/drive the child
  itself instead of using the generic erlexec runtime (§6). If absent, the
  runtime owns spawning, stdin, interrupt, and termination via the mandatory
  `RepoBuilder.Harness.command/1`. All four are @optional_callbacks so a minimal
  adapter compiles cleanly under warnings-as-errors.
  """
  @typedoc "Opaque, adapter-owned handle to a live harness child process."
  @type session :: term()

  @callback start_session(RepoBuilder.Harness.start_opts()) :: {:ok, session()} | {:error, term()}
  @callback send_input(session(), iodata()) :: :ok | {:error, term()}
  @callback interrupt(session()) :: :ok
  @callback terminate(session()) :: :ok

  @optional_callbacks start_session: 1, send_input: 2, interrupt: 1, terminate: 1
end
```

> **Why two behaviours.** Behaviours provide **no** default implementations; under `warnings_as_errors: true` a missing mandatory callback is a hard compile error. Splitting keeps the minimal adapter (`command/1` + `normalize/2`) compiling while still typing the bespoke path. The session runtime checks `function_exported?(adapter, :start_session, 1)` (i.e. whether the adapter implements `CustomSpawn`): if yes it delegates spawn/stdin/interrupt/terminate to the adapter; if no it spawns via `command/1` and owns the lifecycle itself. The stdin callback is **`send_input/2`**, deliberately NOT `send/2`, to avoid shadowing `Kernel.send/2` inside adapters and the runtime (matching the §6 helper `send_stdin/2`).

> **`@spec` note for adapters.** A `command/1`/`normalize/2`/`send_input/2`/… implementation is already specced by its `@callback`; per §3 rule 1's exemption it needs no repeated `@spec`. Any *additional* public function an adapter exposes (helpers, `env/1`) DOES require `@spec`.

### 4.3 Mapping tables (grounded in the research)

**General normalization rules (apply to both):**

- One `Jason.decode/1` per JSONL line → `normalize(raw, ctx)` → `{:ok, [event]} | :skip | {:error, reason}`. Single-bad-line tolerance is load-bearing; both real reference parsers swallow per-line decode errors and never crash a stream.
- Split stdout on `"\n"` **only**, strip a trailing `"\r"`. Do **not** treat U+2028/U+2029 as line breaks — they appear legitimately inside JSON string payloads (pi).
- **Multibyte / partial-UTF-8 framing.** stdout chunks may split a multibyte UTF-8 character (or any JSON token) across two messages. The `buf: binary()` accumulator (§6) holds raw bytes and is only ever cut on a literal `"\n"` byte (0x0A), which can never fall inside a UTF-8 multibyte sequence — so a complete NEWLINE-terminated line is always valid UTF-8 and `Jason.decode/1` is safe on it. Do **not** run `String.split/2` on partial buffer contents or validate UTF-8 before a newline is seen; accumulate bytes, split on `"\n"`, decode only complete lines, and carry the trailing partial bytes forward untouched.
- `tool_result` is kept in the contract but is usually not rendered as its own UI card on either path; downstream may ignore it.

**pi `--mode json` RAW → CANONICAL** (lifecycle: `session → agent_start → turn_start → message_start → message_update → message_end → tool_execution_* → turn_end → agent_end`, plus `auto_retry_end` on failure):

| pi raw frame | Canonical |
|---|---|
| `session{id}` (FIRST line) | `:session_started` (`session_id = .id`, `harness: :pi`) |
| `agent_start` / `turn_start` / `message_start` | `:skip` (lifecycle noise) |
| `message_update` `assistantMessageEvent.type == text_delta` | `:text_delta` (`thinking?: false`) — local parser defers to `message_end` |
| `message_update` `assistantMessageEvent.type == thinking_delta` | `:text_delta` (`thinking?: true`) |
| `message_end` (content has text) | `:text_delta` (finalized text) + `:usage` if usage present |
| `message_end` (thinking only) | `:text_delta` (`thinking?: true`) + `:usage` |
| `message_end` (usage only, no text) | `:usage` |
| `turn_end` (`message.usage` present) | `:usage` (else `:skip`) |
| `tool_execution_start{toolName, args, toolCallId}` | `:tool_call` (`name = toolName`, `input = args`, `id = toolCallId`) |
| `tool_execution_end{toolName, result, isError, toolCallId}` | `:tool_result` (`is_error = isError`, `content = result`, `id = toolCallId`) |
| `agent_end{messages}` | `:done` (`ok: true`, `reason: :agent_end`) + derive `:usage` from last message |
| `auto_retry_start` | `:status` (`kind: :retry`) or `:skip` |
| `auto_retry_end{success: false, finalError}` | `:error` (`message = finalError`, `reason: :auto_retry_exhausted`, `retryable` derived) |
| `compaction_*` / `queue_update` / unknown | `:skip` |
| **[SYNTHESIZED]** clean exit code 0 + output + no error + no `agent_end` | `:done` (`ok: true`, `reason: :clean_exit`) |
| **[SYNTHESIZED]** idle timer fires while child still running | `:error` (`reason: :idle_timeout`, `retryable: true`) — runtime kills the child |

> **pi quirks you MUST handle:**
> - **No single terminal `is_error` result line.** Success is derived: reaching `agent_end` cleanly, OR a clean process exit (returncode 0) after a final `message_end` with real output and no error. **zai/GLM ends on `message_end` + exit 0 with NO `agent_end` at all.** Synthesize `:done` from `(agent_end) OR (clean-exit heuristic)`. If you wait only for `agent_end`, a successful zai/GLM run hangs forever — bound it with the **idle timeout** wired into the runtime (§6): reference defaults `PI_STREAM_IDLE_TIMEOUT=300s`, `PI_EXIT_GRACE_SECONDS=10`, `PI_KILL_GRACE_SECONDS=5`. The idle path emits `%Error{reason: :idle_timeout}`; the clean-exit path emits `%Done{reason: :clean_exit}`.
> - **No per-run USD cost in the stream.** Derive pi cost downstream: `(tokens / 1e6) * price_per_mtok` from your own price table; unpriced model → warn and leave `cost_usd` **nil**.
> - **Usage shape is provider-polymorphic.** Try all three: Anthropic-shaped `input_tokens`/`output_tokens`; OpenAI-shaped `prompt_tokens`/`completion_tokens`; pi-native (zai/GLM) bare `input`/`output` (+ `cacheRead`/`cacheWrite`/`totalTokens`).
> - **camelCase** field names in pi tool events (`toolName`, `toolCallId`, `args`, `isError`, `result`, `finalError`). Outer envelope `type` and inner `assistantMessageEvent.type` are **two different discriminators** — don't conflate them.

**Claude `stream-json` RAW → CANONICAL** (headless: `claude -p --output-format stream-json --verbose`; `--include-partial-messages` for token deltas):

| Claude raw frame | Canonical |
|---|---|
| `system` `subtype: init {session_id, model, tools, mcp_servers, plugins}` | `:session_started` (`harness: :claude`) |
| `system` `subtype: api_retry {attempt, max_retries, retry_delay_ms, error, error_status}` | `:status` (`kind: :retry`) |
| `system` `subtype: plugin_install {status, name, error}` | `:status` (`kind: :plugin_install`) |
| `assistant` → `TextBlock{text}` | `:text_delta` (`thinking?: false`) |
| `assistant` → `ThinkingBlock{thinking}` | `:text_delta` (`thinking?: true`) |
| `assistant` → `ToolUseBlock{id, name, input}` | `:tool_call` |
| `assistant.usage` / `message_id` | `:usage` (per-message) |
| `user` → `ToolResultBlock{tool_use_id, content, is_error}` | `:tool_result` |
| `user` (plain echo) | `:skip` |
| `stream_event` `event.delta.type == text_delta` → `event.delta.text` | `:text_delta` (partial; needs `--include-partial-messages`) |
| `rate_limit` / `RateLimitEvent` | `:status` (`kind: :rate_limit`) |
| `result` `subtype: success {total_cost_usd, usage, duration_ms, num_turns, result, is_error}` | `:done` (`ok = not is_error`) + `:usage` + `cost_usd` |
| `result` `subtype: error_*` | `:error` (message from `errors[]`/`result`, `reason: :provider_error`) + map `:done.reason` |

> **Claude quirks you MUST handle:**
> - Token-level text deltas require **BOTH** `--output-format stream-json` **AND** `--verbose` **AND** `--include-partial-messages`. Without the flags you get whole content blocks, not deltas. The real delta is nested at `StreamEvent.event.delta.text` where `event.delta.type == "text_delta"` — **not** a top-level `.text`.
> - `system` messages multiplex by `subtype` (`init` → `:session_started`; `api_retry`/`plugin_install` → `:status`).
> - `ResultMessage.subtype` enum maps to canonical `reason`: `"success" → :success`, `"error_during_execution" → :error_during_execution`, `"error_max_turns" → :max_turns`, `"error_max_budget_usd" → :max_budget`, `"error_max_structured_output_retries" → :max_structured_output_retries`.
> - On `subtype: "success"`, `is_error` can **still** be true if the final API request failed (check `api_error_status`). `:done.ok` must reflect `is_error`, not just subtype.
> - **Claude version:** CLI flags confirmed from docs fetched 2026-06-15; an exact "latest stable" CLI version number was **not printed** on the fetched pages — treat the CLI version as **verify** at install time, validate the flag set against `claude --help` before relying on it. snake_case field names (`tool_use_id`, `is_error`, `input`).

---

## 5. OTP Supervision Tree

```
RepoBuilder.Application (Supervisor, strategy: :one_for_one)
│
├── RepoBuilderWeb.Telemetry          # metrics/telemetry; start FIRST (handlers attached here, §13)
├── RepoBuilder.Repo                   # Ecto/Postgres; needed before Endpoint/Oban
├── {Phoenix.PubSub, name: RepoBuilder.PubSub}   # canonical-event fan-out bus
├── {Oban, oban_config()}              # durable jobs / cron / webhook triggers (needs Repo)
│
├── {Registry, keys: :unique, name: RepoBuilder.SessionRegistry}
│        # lookup a live session GenServer by agent/session id
│
├── {RepoBuilder.Session.Admission, ...}   # capacity / concurrency gate for live sessions (below)
│
├── {DynamicSupervisor, name: RepoBuilder.SessionSupervisor,
│      strategy: :one_for_one, max_children: <N>}
│        # one supervised child per LIVE harness session (§6). Crash isolation:
│        # one agent crashing restarts ONLY that agent (children are :temporary by default —
│        # a finished/crashed live session is not auto-restarted; the workflow engine
│        # or operator decides re-run policy). max_children bounds OS process/fd usage.
│
├── {DynamicSupervisor, name: RepoBuilder.WorkflowSupervisor, strategy: :one_for_one}
│        # one supervised process tree / state machine per RUNNING ADW (§7).
│        # A failed step is isolated to its workflow, never catastrophic.
│
├── RepoBuilder.OrphanReaper            # on startup: reconcile/clean orphaned OS children via the
│                                       # durable os_pid ledger (§6) — runs AFTER Repo is up.
│
└── RepoBuilderWeb.Endpoint            # HTTP/WebSocket entry; start LAST (after Repo + PubSub)
```

**Child rationale & restart strategy:**

- **Telemetry first / Endpoint last.** The default Phoenix order: Telemetry, Repo, PubSub, Endpoint. Started in order, stopped in reverse. Endpoint must come up after Repo and PubSub are available. Telemetry first so its handlers (§13) are attached before any Repo/Oban events fire.
- **Repo** before **Oban**, **OrphanReaper**, and **Endpoint** — all need the DB. OrphanReaper reads the durable ledger table, so it MUST start after Repo.
- **SessionRegistry** (`:unique`) maps a session/agent id → the live GenServer pid for `send_input`/`interrupt`/observability targeting.
- **Session.Admission** is a small GenServer (or `:counters`-backed gate) enforcing live-session **concurrency limits**. Before `SessionSupervisor.start_child/2`, the runtime acquires a slot (configurable `max_live_sessions`, default e.g. 100); if no slot is free it returns `{:error, :at_capacity}` to the caller (workflow runner / controller), which queues or rejects rather than exhausting OS processes/fds. This is distinct from Oban queue concurrency (which bounds durable jobs); live sessions need their own admission control because `SessionSupervisor` is otherwise an unbounded `DynamicSupervisor`. Also set `max_children` on `SessionSupervisor` as a hard backstop.
- **SessionSupervisor** (DynamicSupervisor) starts/stops live sessions on demand. Live-session children are **`:temporary`** (a completed or crashed run is not automatically restarted — restart is a deliberate orchestration decision; "permanent restart" of an AI run could replay side effects). One crash takes down only that one session.
- **WorkflowSupervisor** (DynamicSupervisor) supervises one running ADW each. A step failure is contained to its workflow; the workflow's own state machine decides retry/branch/abort.
- **OrphanReaper** runs once at boot to reconcile and kill any OS child processes recorded in the durable **os_pid ledger** that are no longer owned by a live GenServer (see the orphan-prevention guarantee in §6).

---

## 6. Session Runtime (GenServer-per-agent over the harness child process)

**One supervised `GenServer` per live agent/orchestrator session**, started under `RepoBuilder.SessionSupervisor` (after acquiring an admission slot, §5) and registered in `RepoBuilder.SessionRegistry` by agent/session id. Each GenServer **owns exactly one harness CLI child process** and is the single writer of that session's canonical events to PubSub and the DB.

### Chosen OS-process primitive: **erlexec 2.3.4**

erlexec is the recommended spawn primitive (wrapped in your GenServer) because it is the only option that natively provides all four needs at once for a streaming-NDJSON agent CLI:

1. **Per-process async stdout** delivered as `{:stdout, OsPid, Data}` messages to the GenServer (line-buffer + JSON-decode there).
2. **stdin** via `:exec.send(os_pid, iodata)` and `:exec.send(os_pid, :eof)`.
3. **Clean interrupt** via `:exec.stop/1` with `{:kill_timeout, N}` for SIGTERM→SIGKILL escalation, and `{:group, 0}` + `:kill_group` to reap the whole subtree.
4. **Termination monitoring** via the `:monitor` option / `{:DOWN, ...}` messages.

> **When to use muontrap instead / additionally:** for a fire-and-forget / log-to-Logger child where the requirement is "never leak an OS process even on BEAM SIGKILL", muontrap + cgroups gives the strongest subtree-kill guarantee. erlexec's exec-port only reaps children on a **clean** emulator exit; on a hard BEAM SIGKILL the children survive (closed only by the durable-ledger reaper below). For containment-critical work where a hard-SIGKILL subtree kill is mandatory, run that child via muontrap with cgroups (Linux). muontrap's own README says it is "not great for interactive programs that communicate via the port or send signals" and points to erlexec — so muontrap is the **worse** fit for the interactive streaming harness but the right fit for the pure-containment path. Raw `Port` is acceptable only if you accept writing the bash stdin-watchdog wrapper yourself and own all buffering/backpressure.

### Orphan-prevention guarantee (durable os_pid ledger)

A reaper that only reads in-memory state cannot survive a BEAM crash — after a hard SIGKILL the Registry, all GenServer state, and any in-memory pid record are gone, and erlexec only reaps on a *clean* exit. The guarantee therefore rests on a **durable ledger in Postgres**, plus a uniquely-tagged env marker so we never kill a pid that has been recycled by an unrelated process.

- **On every `:exec.run` success**, before streaming begins, insert one `os_pid_ledger` row: `{id, agent_id, session_id, os_pid, marker, argv_hash, started_at, node}`. `marker` is a per-session random token also injected into the child's environment as `REPO_BUILDER_SESSION_MARKER=<marker>` (and into a wrapper-written pidfile `priv/run/<marker>.pid` when muontrap/wrapper is used). The marker is what lets us prove a live OS process is **ours**.
- **On `terminate/2`** (normal stop, crash, or interrupt), delete the ledger row after `:exec.stop/1`. `terminate/2` is **idempotent** (guard on `os_pid`).
- **At app startup, `RepoBuilder.OrphanReaper`** (started after Repo) reads every `os_pid_ledger` row whose `node` matches this node. For each row it verifies the live process is actually ours **before** sending any signal — never kill by bare pid alone:
  - Read `/proc/<os_pid>/environ` (Linux) and confirm it contains `REPO_BUILDER_SESSION_MARKER=<marker>`, OR confirm the wrapper pidfile `priv/run/<marker>.pid` still maps to `os_pid`.
  - Only on a positive marker match: `:exec.kill(os_pid, :sigterm)` then SIGKILL after a grace period (or `kill -KILL -<pgid>` for the group). Then delete the row.
  - If the pid is dead or the marker does not match (recycled pid / unrelated process), just delete the stale row.
- This closes the gap the Elixir `Port` docs call out ("won't be automatically terminated" if the VM crashes). For the strongest subtree guarantee on Linux, additionally place containment-critical children in a cgroup via muontrap so a single cgroup kill reaps the whole descendant tree.

### GenServer responsibilities (in order)

1. **Acquire an admission slot** (§5) and **resolve credentials** for `start_opts.secrets` (§ "Secrets" below) — never log them. **Spawn** via the adapter's `command/1` → `:exec.run([exe | args], [:stdin, :stdout, :stderr, :monitor, {:group, 0}, :kill_group, {:kill_timeout, 5}, {:env, env_with_marker}, {:cd, cwd}])`. `Process.flag(:trap_exit, true)` so child death becomes a typed message. **Write the os_pid ledger row** (durable orphan ledger above) before consuming output.
2. **Buffer partial NDJSON.** stdout arrives in **arbitrary chunks, not newline-framed**, and a multibyte UTF-8 char or JSON token may split across chunks. Keep a `buf: binary()` byte accumulator in a typed `%State{}` (`@enforce_keys`), split on `"\n"` (byte 0x0A) only, keep the trailing partial fragment untouched, flush it on exit. A NEWLINE-terminated line is always valid UTF-8 (§4.3), so decode only complete lines.
3. **Decode + validate** each complete line: `Jason.decode/1` → adapter `normalize/2`. Optionally run the decoded map through a TypeCheck wire-type `conforms/2` before normalization. A malformed line becomes a `:skip` or a `{:error, _}` logged event — **never** a crash.
4. **Persist** each canonical event after **redaction** (§4.1): scrub `raw` of secrets, insert `agent_logs` row, update agent/session status, accumulate usage/cost (float→`Decimal.from_float/1` at this boundary, §8). See §8.
5. **Broadcast** each canonical event (full, unscrubbed `raw` for the live UI) via `Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "agent:#{id}:events", {:harness_event, event})` (and a workflow/global topic as needed). Tagged tuples only.
6. **Backpressure:** erlexec/Ports have **no inbound flow control** — a chatty child can flood the mailbox and OOM the node. The erlexec path bounds this itself (it is NOT a muontrap child, so `:stdio_window` is unavailable here): process each `{:stdout, _, chunk}` **synchronously** in `handle_info` (no spawning a task per chunk), keep a bounded internal accumulator, and if `byte_size(buf)` exceeds a hard cap (e.g. a single un-newline-terminated line > `max_line_bytes`, default 1 MB) treat the stream as hostile — emit `%Error{reason: :provider_error, message: "stdout overflow"}`, `:exec.stop/1` the child, and stop. The `:stdio_window` (default 10 KB) belongs **only** to the muontrap containment alternative, not the erlexec session path.
7. **Idle timeout (wired into the runtime).** In `init`, arm `idle_ref = Process.send_after(self(), :idle_timeout, idle_ms)` (default 300_000 ms). On every `{:stdout, ...}` chunk, **reset** the timer (`Process.cancel_timer(idle_ref)` then re-arm). A `handle_info(:idle_timeout, ...)` clause `:exec.stop/1`s the child and emits `%Error{reason: :idle_timeout, retryable: true}` (§4.1). On `{:DOWN, os_pid, :process, _, reason}` with no `agent_end` seen, synthesize `%Done{reason: :clean_exit}` if the exit was clean (code 0) with prior output; otherwise emit `%Error{reason: :provider_error}`.

### Secrets / credential sourcing (never logged)

- Harness credentials (`ANTHROPIC_API_KEY`, pi provider creds, etc.) are sourced at runtime in `config/runtime.exs` from the OS environment and stored under `config :repo_builder, :harness_secrets, %{claude: %{"ANTHROPIC_API_KEY" => ...}, pi: %{...}}` (or per-agent overrides in `agents.config`, but secret VALUES are referenced by env-var name, never persisted in the DB).
- The runtime resolves the per-harness secret map into `start_opts.secrets`, and the adapter's `command/1` places them in the child's **`env`** (never in argv, which is visible in `ps`). Secrets are excluded from all log lines, from the redacted `raw` (§4.1), and from `system_logs`/`agent_logs`. Add a Logger metadata filter / redactor so an accidental `inspect/1` of `start_opts` does not leak them.

### Per-session workspace / cwd isolation

- Each session runs in an **isolated working directory** so concurrent agents cannot stomp each other's files. On start, the runtime provisions `priv/workspaces/<session_id>/` (or a configurable base, ideally a tmpfs/scratch volume in prod), passes it as `start_opts.cwd` / erlexec `{:cd, cwd}`, and records it in state.
- On `terminate/2`, clean up the workspace (configurable: delete, or retain-on-failure for debugging with a retention sweep). Workspaces are per-session and never shared; the cleanup is idempotent and tolerant of an already-removed directory.

Reference skeleton (erlexec-wrapped GenServer) — adapt; do not copy verbatim into the real adapters:

```elixir
defmodule RepoBuilder.Session.Server do
  use GenServer
  require Logger
  alias RepoBuilder.Harness.Event

  @idle_ms 300_000

  defmodule State do
    use TypedStruct
    typedstruct enforce: true do
      field :agent_id, String.t()
      field :session_id, String.t()
      field :harness, atom()
      field :adapter, module()
      field :session_ctx, term(), enforce: false
      field :os_pid, non_neg_integer(), enforce: false
      field :cwd, Path.t()
      field :marker, String.t()
      field :sink, pid()
      field :buf, binary(), default: ""
      field :idle_ref, reference(), enforce: false
      field :saw_agent_end, boolean(), default: false
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(opts[:agent_id]))

  @spec send_stdin(String.t(), iodata()) :: :ok
  def send_stdin(agent_id, data), do: GenServer.cast(via(agent_id), {:stdin, data})

  defp via(id), do: {:via, Registry, {RepoBuilder.SessionRegistry, id}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    # ... acquire admission slot (§5); resolve secrets (never log); provision cwd workspace;
    # call adapter.command/1; :exec.run/2 with kill_group + kill_timeout + {:env, env_with_marker};
    # insert os_pid_ledger row BEFORE consuming output (durable orphan ledger).
    idle_ref = Process.send_after(self(), :idle_timeout, @idle_ms)
    {:ok, struct!(State, Keyword.put(opts, :idle_ref, idle_ref))}
  end

  @impl true
  def handle_info({:stdout, os_pid, chunk}, %State{os_pid: os_pid, buf: buf} = st) do
    st = reset_idle(st)
    bin = buf <> chunk

    cond do
      no_newline?(bin) and byte_size(bin) > max_line_bytes() ->
        emit(%Event.Error{harness: st.harness, message: "stdout overflow",
                          reason: :provider_error}, st)
        _ = :exec.stop(os_pid)
        {:stop, :normal, %{st | buf: ""}}

      true ->
        {lines, rest} = split_lines(bin)   # split on "\n" only; rest = trailing partial bytes
        Enum.each(lines, &handle_line(&1, st))
        {:noreply, %{st | buf: rest}}
    end
  end

  def handle_info(:idle_timeout, %State{os_pid: os_pid} = st) do
    _ = :exec.stop(os_pid)
    emit(%Event.Error{harness: st.harness, message: "idle timeout",
                      reason: :idle_timeout, retryable: true}, st)
    {:stop, :normal, st}
  end

  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %State{os_pid: os_pid} = st) do
    if st.buf != "", do: handle_line(st.buf, st)
    # synthesize :done (:clean_exit) for pi if clean exit + output + no agent_end seen
    maybe_synthesize_done(reason, st)
    {:stop, :normal, %{st | buf: ""}}
  end

  @impl true
  def terminate(_reason, %State{os_pid: os_pid} = st) when is_integer(os_pid) do
    _ = :exec.stop(os_pid)            # SIGTERM, then SIGKILL after kill_timeout; idempotent
    delete_os_pid_ledger(st)          # remove durable ledger row
    cleanup_workspace(st)             # idempotent per-session cwd cleanup
    :ok
  end
  def terminate(_reason, _st), do: :ok

  defp reset_idle(%State{idle_ref: ref} = st) do
    if ref, do: Process.cancel_timer(ref)
    %{st | idle_ref: Process.send_after(self(), :idle_timeout, @idle_ms)}
  end

  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(bin) do
    parts = String.split(bin, "\n")   # "\n" only; never U+2028/U+2029
    {complete, [partial]} = Enum.split(parts, length(parts) - 1)
    {complete, partial}
  end

  @spec handle_line(binary(), State.t()) :: :ok
  defp handle_line("", _st), do: :ok
  defp handle_line(line, %State{adapter: mod, session_ctx: ctx} = st) do
    line = String.trim_trailing(line, "\r")
    with {:ok, raw} <- Jason.decode(line),
         {:ok, events} <- mod.normalize(raw, ctx) do
      Enum.each(events, &dispatch(&1, st))
    else
      :skip -> :ok
      {:error, _} -> Logger.debug("non-json/unhandled line: #{inspect(line)}")
    end
    :ok
  end

  @spec dispatch(Event.t(), State.t()) :: :ok
  defp dispatch(event, %State{agent_id: id} = st) do
    persist(RepoBuilder.Harness.Redact.scrub(event), st)   # redact secrets before DB (§4.1/§8)
    Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "agent:#{id}:events", {:harness_event, event})
    :ok
  end
end
```

---

## 7. Workflow / ADW Engine

An **ADW** is a deterministic, composable chain of steps (e.g. `plan → build → review → fix`). **Step order and branching are fixed and known**; the **intelligent work inside a step is delegated to a harness** through the adapter. A failed step is isolated, not catastrophic.

### Model

- A **workflow definition** is durable data (§8): an ordered list of typed steps, each with `{name, harness, provider, model, prompt_template, on_success, on_failure}` and explicit inputs/outputs.
- A **running workflow** is a supervised process / explicit state machine under `RepoBuilder.WorkflowSupervisor`, one per run, holding its own typed `%WorkflowState{}` (current step, accumulated artifacts, status).

### Step lifecycle state machine

```
pending → running → (succeeded | failed | cancelled)
   │          │
   │          └── on success: follow step.on_success edge (next step | :done)
   │          └── on failure: follow step.on_failure edge (retry | branch | :abort)
   └── deterministic transitions only; the AI does the work INSIDE :running
```

Each `:running` step:
1. Renders its prompt template from accumulated workflow artifacts (deterministic).
2. Starts a **live session** (§6) for that step's harness, OR — for durable/triggered runs — enqueues an **Oban job** (next subsection).
3. Subscribes to the session's canonical events, captures `:done`/`:error` plus the final text/usage as the step's output.
4. Applies the deterministic `on_success`/`on_failure` edge.

### Durable execution split + crash-resume contract (be explicit)

- **`workflow_runs` is the source of truth for run position.** Every deterministic transition (step start, step success/failure, current_step change, accumulated artifacts, total_cost_usd) is **persisted to `workflow_runs` before** the next step begins. The in-memory `WorkflowEngine.Runner` GenServer is a fast cache of this row, not the system of record.
- **Live, sub-second streaming sessions stay in GenServers** (SessionSupervisor). In-memory streaming state is lost on crash *by design* (it is reconstructable from `agent_logs`).
- **Durable, triggered, and scheduled work goes through Oban** (§ below + §5): each durable step is an Oban worker; chain steps by inserting the next job from `perform/1`.
- **Crash-resume mechanism.** On node restart, a boot reconciler (an Oban cron `WorkflowResume` worker, or a one-shot task after Repo) queries `workflow_runs` for `status IN (:queued, :running)` rows that have no live `Runner` (none survive a restart) and **re-enqueues** the next durable step (keyed off `current_step`) via `StepWorker`, idempotently (unique job on `{workflow_run_id, step_name}`, §13). Thus an in-flight workflow resumes from its persisted position; the in-flight live session is not replayed, but its step is re-driven from `current_step`. A mid-run crash therefore does **not** lose the run — it loses at most the in-progress live stream, which the resumed step re-creates. This satisfies the "survives node restart" acceptance criterion (M5 / Done #6).
- **Pattern:** the workflow's GenServer drives the live step; at each durable checkpoint/side-effect it persists `workflow_runs` and enqueues an Oban job so the work is retried and survives node loss. Do **not** push hot, sub-second streaming through Oban (DB round-trips); do **not** rely on GenServer memory for anything that must survive a deploy.

> Multi-job DAG dependencies, batches, and chained execution are Oban **Pro** features. Build on **OSS**: chain steps manually by enqueuing the next job from a worker's `perform/1`. Treat Pro as an optional upgrade, never a requirement.

---

## 8. Persistence (Ecto + PostgreSQL)

Mirror the proven TAC schema. **binary_id (UUID) PKs app-wide.** `Ecto.Enum` for provider/status/level/role (closed domains). The **harness** identity is stored as a validated `:string` (open; see §3/§10), not an Enum. **JSONB (`:map`)** for event payloads & usage. All DB access lives behind `@spec`'d **context** modules — controllers, LiveViews, and OTP processes never touch `Repo`/`Ecto.Query` directly.

### Shared base macro

```elixir
defmodule RepoBuilder.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
```

### Schemas (typed; one per file under `lib/repo_builder/<context>/`)

| Table | Purpose | Key fields (types) |
|---|---|---|
| `agents` | durable agent definitions | `name :string`, `harness :string` (validated vs registry), `provider Ecto.Enum[:anthropic,:openai,:local]`, `status Ecto.Enum[:idle,:running,:error]`, `config :map` |
| `agent_logs` | one row per canonical event for an agent/session | `agent_id` (FK), `session_id :string`, `event_type Ecto.Enum[:session_started,:text_delta,:tool_call,:tool_result,:usage,:status,:done,:error]`, `harness :string`, `payload :map` (JSONB, **secret-redacted** `raw`), `usage :map` (JSONB, nullable), `log_no :integer` (durable readable per-row identifier surfaced in the console drilldown as `log-<n>`; sequence-backed, `read_after_writes`) |
| `system_logs` | app-level/system events | `level Ecto.Enum[:debug,:info,:warn,:error]`, `message :string`, `metadata :map` |
| `prompts` | reusable prompt templates | `name :string`, `body :text`, `variables :map` |
| `chat` | conversational turns (user/assistant) | `agent_id` (FK), `role Ecto.Enum[:user,:assistant,:system]`, `content :text`, `usage :map` |
| `workflows` | durable ADW definitions | `name :string`, `state Ecto.Enum[:draft,:active,:archived]`, `steps :map` (JSONB ordered list), `metadata :map` |
| `workflow_runs` | one row per execution; **source of truth for run position** (§7) | `workflow_id` (FK), `status Ecto.Enum[:queued,:running,:succeeded,:failed,:cancelled]`, `current_step :string`, `artifacts :map`, `total_cost_usd :decimal` (nullable; `NULL` = unpriced) |
| `os_pid_ledger` | durable record of live OS child pids for boot-time orphan reaping (§6) | `agent_id` (FK), `session_id :string`, `os_pid :integer`, `marker :string`, `argv_hash :string`, `node :string`, `started_at :utc_datetime_usec` |

**Typed rules:**

- Hand-write a precise `@type t :: %__MODULE__{...}` per schema — the auto-generated `t()` (`optional(atom()) => any()`) gives Dialyzer almost nothing.
- Use `Ecto.Enum` literal unions in the `@type` (e.g. `status: :queued | :running | ...`) for the closed-domain columns so Dialyzer matches the DB exactly. Keep the `values:` list and any DB CHECK in lockstep; Enum casting **raises** on an out-of-list stored value. `harness` is `String.t()` (open) and validated via `validate_inclusion/3` against the registry (§3).
- **JSONB loads back with STRING keys.** Store string-keyed maps; never `String.to_atom/1` untrusted JSON keys. Model structured usage as a typed `embedded_schema` value object `RepoBuilder.Logs.Usage` (`input_tokens`, `output_tokens`, `cost_usd :decimal`) embedded via `embeds_one` + `cast_embed/3`.
- **Cost float→Decimal boundary.** The canonical `Usage.cost_usd` / `Done.cost_usd` are `float()` (§4.1). They are converted **here, at persistence**, with `Decimal.from_float/1` when writing `agent_logs.usage.cost_usd` and rolling into `workflow_runs.total_cost_usd`. Preserve the nil-vs-0.0 distinction: an unpriced event's `cost_usd` is `nil` → store SQL `NULL` (never `0`); a priced-at-zero event stores `Decimal.new(0)`.
- **Changeset is the typed boundary:** every write goes through `cast/4` + validations; `unique_constraint`/`foreign_key_constraint` only work if the matching index/FK exists in a migration — otherwise you get a raw Postgrex exception, not `{:error, changeset}`.

### Context modules (the typed seam)

`RepoBuilder.Agents`, `RepoBuilder.Logs`, `RepoBuilder.Prompts`, `RepoBuilder.Chats`, `RepoBuilder.Workflows`, `RepoBuilder.OsPidLedger`. Every public function carries an `@spec` and returns `{:ok, t()} | {:error, Ecto.Changeset.t()}` (or `[t()]` / `t() | nil`).

### Migration shape (binary_id + JSONB + Enum-as-string + FK)

```elixir
create table(:agents, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :name, :string, null: false
  add :harness, :string, null: false          # open identity, validated vs registry (NOT a DB enum)
  add :provider, :string, null: false
  add :status, :string, null: false, default: "idle"
  add :config, :map, default: %{}             # -> jsonb on Postgres
  timestamps(type: :utc_datetime_usec)
end
create unique_index(:agents, [:name])

create table(:agent_logs, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
  add :session_id, :string
  add :event_type, :string, null: false
  add :harness, :string
  add :payload, :map, default: %{}            # secret-redacted raw frame
  add :usage, :map
  timestamps(type: :utc_datetime_usec)
end
create index(:agent_logs, [:agent_id])
create index(:agent_logs, [:session_id])

create table(:os_pid_ledger, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all)
  add :session_id, :string, null: false
  add :os_pid, :integer, null: false
  add :marker, :string, null: false           # also injected as REPO_BUILDER_SESSION_MARKER env
  add :argv_hash, :string
  add :node, :string, null: false
  add :started_at, :utc_datetime_usec, null: false
end
create index(:os_pid_ledger, [:node])
create unique_index(:os_pid_ledger, [:marker])
```

Decide binary_id at schema-design time for **all** application tables — retrofitting bigserial→uuid later is a painful data migration.

> **Oban + binary_id note.** The application default `@primary_key {:id, :binary_id, ...}` applies only to your `use RepoBuilder.Schema` schemas. **Oban's own tables (`oban_jobs`, etc.) use `bigint` job ids** and are created by `Oban.Migration.up/0` — do **not** force `binary_id` onto Oban's tables, and do not be surprised that `oban_jobs.id` is a bigint. The two id schemes coexist fine; foreign keys from your tables to Oban jobs (if any) must use `:bigint`/`:integer`, not `:binary_id`.

---

## 9. LiveView Observability Dashboard

Server-rendered, real-time, swimlane-style. Subscribes to canonical events over PubSub; renders **append-only logs via LiveView STREAMS**; loads cost/status via `assign_async`/`start_async`.

### Wiring

- **Subscribe only when `connected?(socket)`** — `mount/3` runs twice (static render, then live socket); subscribing on the disconnected render leaks/duplicates.
- `Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:#{id}:events")` in `mount`; the session GenServer broadcasts `{:harness_event, %Event.*{}}`; handle in `handle_info/2` with **one clause per canonical variant** (exhaustive, Dialyzer-friendly).

### Streams for append-only logs (the idiom)

Keeping the log list in an assign forces LiveView to retain the entire collection in the socket + per-item change-tracking — the process heap grows unbounded and every diff is O(n). **Streams keep items in the client DOM only**; server memory stays flat.

- `stream_configure(:logs, dom_id: &"log-#{&1.id}")` then `stream(:logs, [])` in mount.
- On each event: `stream_insert(socket, :logs, entry, at: -1, limit: -500)` — append at bottom, **negative** limit prunes the oldest from the top (sign convention: positive prunes from the END, negative from the BEGINNING). Container needs a unique DOM id; every child needs an id; `phx-update="stream"`.
- **Swimlane rows** (one per agent/step, mutating `running → done`) use `stream_insert` with a **stable dom_id** so re-inserting the same id **replaces in place**.

### Live cost/status (async)

- `assign(:cost, AsyncResult.loading())` then `assign_async(:cost, fn -> {:ok, %{cost: RepoBuilder.Logs.cost_rollup!(id)}} end)`; render with `<.async_result :let={cost} assign={@cost}>` + `<:loading>`/`<:failed>` slots. Async tasks start **only** on a connected socket — always provide a loading placeholder.
- `start_async` + `handle_async/3` (match both `{:ok, _}` and `{:exit, _}`, pairing `AsyncResult.ok/2` / `AsyncResult.failed/2`) for manual refreshes.

### Reconnect handling (critical)

Streams live in the browser DOM; PubSub is fire-and-forget with no buffering. On reconnect, `mount/3` runs again and the stream is re-seeded from whatever mount puts in it — events broadcast **while disconnected are gone**. Therefore: in `mount`, **load the last N persisted `agent_logs` rows and seed the stream**, track a last-seen cursor/id, then subscribe — so the dashboard resumes and you can backfill the gap. Do not assume the client DOM survived or that PubSub redelivered anything.

### Components

- Typed function components with `attr/3` + `slot/3` (compile-time validation) for `log_line`, `swimlane_row`, `cost_badge`. Use `values:` to constrain enums (e.g. log level).
- Use `patch` (+ `handle_params/3`) for tab/filter/swimlane switches; `navigate` only for a true LiveView change. Use nested `live_render/3` for a widget you want **process-isolated** so its crash doesn't take down the dashboard.

### LiveDashboard + metrics

- Keep Phoenix LiveDashboard (do not pass `--no-dashboard`). In `RepoBuilderWeb.Telemetry`, define `metrics/0` including the Oban (`[:oban, :job, :stop|:exception]`) and Repo (`[:repo_builder, :repo, :query]`) telemetry, plus app-specific counters (live-session count, cost rollups, error rate). See §13 for handler attachment and alerting.

---

## 10. Provider / Harness Extensibility (add a 3rd harness = one module + config)

Adding a harness is: **(1) implement the mandatory `@behaviour` (and optionally `CustomSpawn`), (2) register it in config, (3) reference it by string.** Because the harness identity is an **open `atom()`/`String.t()`** everywhere (Event `harness :: atom()`, `agents.harness :: String.t()` validated against the registry — NOT a closed `Ecto.Enum`/union), **no core type or schema edit is required.** This is the deliberate design seam (§3 rule 5): the registry is the single source of truth for which harnesses exist.

```elixir
# 1. The adapter (one module) implementing the MANDATORY behaviour.
#    command/1 + normalize/2 only -> the generic erlexec runtime drives it (§6).
#    Callback implementations are specced by @callback; per §3 rule 1 they need no repeated @spec.
#    Any extra public helper (e.g. env/1) DOES need an @spec.
defmodule RepoBuilder.Harness.Cursor do
  @behaviour RepoBuilder.Harness

  @impl true
  def command(opts) do
    {"cursor-agent", ["--json", opts.prompt], env(opts), %{harness: :cursor}}
  end

  @impl true
  def normalize(raw, _ctx) do
    # map Cursor's wire frames -> {:ok, [RepoBuilder.Harness.Event.*{harness: :cursor}]} | :skip
  end

  # Only if Cursor needs bespoke spawning would it ALSO `@behaviour RepoBuilder.Harness.CustomSpawn`
  # and implement start_session/1, send_input/2, interrupt/1, terminate/1 (all optional).

  @spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
  defp env(opts), do: Map.get(opts, :secrets, %{}) |> Map.to_list()
end
```

```elixir
# 2 + 3. Registry/config shape (config/config.exs) — the SINGLE source of truth.
config :repo_builder, :harnesses, %{
  "claude" => %{module: RepoBuilder.Harness.Claude, exe: "claude",       default_model: "claude-...", price_table: %{}},
  "pi"     => %{module: RepoBuilder.Harness.Pi,     exe: "pi",           default_model: "...",        price_table: %{"glm-..." => 0.6}},
  "cursor" => %{module: RepoBuilder.Harness.Cursor, exe: "cursor-agent", default_model: "...",        price_table: %{}}
}
```

```elixir
# Resolution helper (typed; the ONLY place that reads the registry).
defmodule RepoBuilder.Harness.Registry do
  @typedoc "Open harness identity (a registry key); intentionally atom()/string, not a closed union (§3 rule 5)."
  @type harness :: atom() | String.t()

  @spec all() :: %{optional(String.t()) => map()}
  def all, do: Application.fetch_env!(:repo_builder, :harnesses)

  @spec known() :: [String.t()]
  def known, do: Map.keys(all())

  @spec fetch(harness()) :: {:ok, module()} | {:error, :unknown_harness}
  def fetch(h) do
    case all()[to_string(h)] do
      %{module: mod} -> {:ok, mod}
      _ -> {:error, :unknown_harness}
    end
  end
end
```

The `agents.harness` / `workflows.steps[].harness` string selects the adapter at runtime via `RepoBuilder.Harness.Registry.fetch/1`. Membership is enforced at write time by `validate_inclusion(:harness, Registry.known())` (§3). The configured module is injected from this one registry — which is also the **single test seam** (§13): tests override the `:harnesses` map entry for the harness under test (e.g. point `"claude"` at `RepoBuilder.Harness.Mock`), never a separate `:harness_adapter` key.

> **What "no core changes" precisely means.** Zero edits to the canonical `Event` types, the `Agent` schema, any `@type`, or the runtime. The only required additions are the new adapter module and a new entry in the `:harnesses` config map. That is the deliberate trade for the open `atom()`/`String.t()` harness identity.

---

## 11. Suggested Module / Directory Layout

```
lib/repo_builder/                      # business domain (the typed boundary)
  application.ex                       # supervision tree (§5)
  repo.ex
  schema.ex                            # use RepoBuilder.Schema base macro (§8)
  agents/                              # context + schema
    agent.ex
  agents.ex
  logs/
    agent_log.ex
    system_log.ex
    usage.ex                           # embedded_schema value object
  logs.ex
  prompts/  prompts.ex
  chats/    chats.ex
  workflows/
    workflow.ex
    workflow_run.ex
  workflows.ex
  os_pid_ledger/                       # durable os_pid ledger schema + context (§6/§8)
    os_pid.ex
  os_pid_ledger.ex
  harness.ex                           # the MANDATORY @behaviour (§4.2)
  harness/
    custom_spawn.ex                    # the OPTIONAL @behaviour (§4.2)
    event.ex                           # canonical event sum type (§4.1)
    redact.ex                          # secret scrubbing for persisted raw (§4.1)
    registry.ex                        # harness registry resolution (§10)
    claude.ex                          # adapter
    pi.ex                              # adapter
    fake.ex                            # FakeHarness (emits canned canonical events) — test/dev
  session/
    server.ex                          # GenServer-per-agent (§6)
    admission.ex                       # live-session concurrency gate (§5)
    supervisor.ex                      # wraps DynamicSupervisor + Registry helpers
  workflow_engine/
    runner.ex                          # running ADW state machine (§7)
    step.ex                            # typed step struct + lifecycle
  orphan_reaper.ex                     # boot-time OS-child reconciliation via ledger (§5/§6)
  workers/                             # Oban workers (§5/§7)
    step_worker.ex
    cron_trigger.ex
    workflow_resume.ex                 # boot/periodic resume of orphaned workflow_runs (§7)

lib/repo_builder_web/                  # web interface
  endpoint.ex  router.ex  telemetry.ex
  components/                          # typed function components (attr/slot)
  controllers/
    webhook_controller.ex             # verifies signature, validates payload -> Oban.insert (§7/§11)
  live/
    dashboard_live.ex                 # swimlanes + streams + async cost (§9)
    agent_live.ex
    workflow_live.ex
```

---

## 12. Phased Milestone Build Plan

Each milestone has concrete deliverables and acceptance criteria. Do not advance until the current milestone's acceptance criteria pass.

**M0 — Scaffold + CI + Dialyzer.**
- Deliverables: `mix phx.new` app (flags in §14); deps added & pinned (§2); `mix.exs` with `elixirc_options: [warnings_as_errors: true]` and the `:dialyzer` block (§3); PLT built; GitHub Actions CI (compile-warnings-as-errors, test, dialyzer with cached PLT); `.dialyzer_ignore.exs` + `list_unused_filters: true`.
- Acceptance: `mix compile --warnings-as-errors`, `mix test`, and `mix dialyzer` all green in CI; PLT cache keyed on OTP+Elixir+`mix.lock`.

**M1 — Harness behaviours + FakeHarness + canonical events + tests.**
- Deliverables: `RepoBuilder.Harness` (mandatory) + `RepoBuilder.Harness.CustomSpawn` (optional) behaviours (§4.2); the canonical `Event` sum type as typed structs with open `harness :: atom()` (§4.1); `RepoBuilder.Harness.Redact`; `RepoBuilder.Harness.Fake` emitting a canned sequence (`session_started → text_delta* → tool_call → tool_result → usage → done`); the JSON normalizer for both Claude and pi mapping tables (§4.3); Mox mock of the mandatory behaviour.
- Acceptance: a minimal adapter implementing only `command/1` + `normalize/2` **compiles clean under warnings-as-errors** (proves optional callbacks are correctly optional); property/boundary tests prove the normalizer never raises on malformed/partial/multibyte-split/unknown lines and returns `:skip` correctly; Claude and pi fixture streams map to the exact expected canonical events (including pi clean-exit synthesis, idle-timeout error, and provider-polymorphic usage); Dialyzer clean.

**M2 — Single live session GenServer driving a real CLI, streaming to LiveView.**
- Deliverables: `Session.Server` (erlexec-wrapped, partial-line + multibyte buffering, idle-timer armed/reset, decode→normalize→broadcast); SessionSupervisor + Registry + Admission gate; per-session cwd workspace provisioning; os_pid ledger writes; a minimal LiveView that subscribes and renders the log stream (no full persistence yet).
- Acceptance: running a real `claude -p --output-format stream-json --verbose` (and a `pi --mode json`) session streams live text/tool events into the dashboard; interrupting the session SIGTERM→SIGKILLs the child with **no orphan** (verify with `ps`); killing the GenServer reaps the OS child; a hung pi session fires the idle timeout and emits `%Error{reason: :idle_timeout}`.

**M3 — Persistence + orphan ledger reaping.**
- Deliverables: all schemas + migrations + contexts (§8) incl. `os_pid_ledger`; session GenServer redacts then persists every canonical event to `agent_logs`, writes/deletes ledger rows, and updates agent status/usage (float→Decimal boundary); `OrphanReaper` reconciles the ledger on boot with marker verification; LiveView reconnect seeds the stream from the last N persisted rows.
- Acceptance: a completed session is fully reconstructable from the DB; reconnecting the LiveView mid-stream shows persisted history; Enum/JSONB round-trips verified; `cost_usd` nil-vs-0.0 preserved as NULL-vs-0; contexts are the only `Repo` callers; after a hard BEAM kill leaves a child running, restart + `OrphanReaper` kills exactly that marked child (and never an unrelated/recycled pid).

**M4 — Workflow / ADW engine.**
- Deliverables: workflow + workflow_run schemas; `WorkflowEngine.Runner` state machine (§7) under WorkflowSupervisor; `workflow_runs` persisted as source of truth at every transition; `plan → build → review → fix` example ADW with deterministic edges; step delegates to a live session and captures `:done`/`:error`.
- Acceptance: the example ADW runs end-to-end; a deliberately failing step is isolated (follows `on_failure`, does not crash the workflow or other workflows); workflow_run rows reflect each transition.

**M5 — Oban triggers (cron + webhook) + durable steps + resume.**
- Deliverables: Oban configured (queues + Cron plugin); `StepWorker` (typed args cast at top of `perform/1`, `{:cancel, reason}` for never-valid args, `unique` key on `{workflow_run_id, step_name}`); a webhook controller that **verifies signature/HMAC + timestamp (replay protection)** then validates+casts payload then `Oban.insert`; a cron-triggered ADW; `WorkflowResume` reconciler (§7).
- Acceptance: a webhook and a cron entry each durably trigger a workflow run that **survives a node restart** (resumes from `workflow_runs.current_step` via `WorkflowResume`); unique-job/idempotency verified (a duplicate webhook/cron does not double-enqueue); an invalid/unsigned webhook is rejected; telemetry logger attached.

**M6 — Multi-harness + provider switching.**
- Deliverables: full Claude and pi adapters; harness registry/config (§10); agent/workflow step selects harness at runtime by string; pi cost derivation from a price table (nil for unpriced).
- Acceptance: the same ADW runs end-to-end under both Claude and pi by changing only the agent/step `harness` string; **adding a third harness is one adapter module + one config entry** (verified by adding a no-op `Cursor` adapter with zero edits to `Event`/`Agent`/runtime); pi cost derived correctly (and `nil` when unpriced).

**M7 — Polish / observability.**
- Deliverables: swimlane dashboard (per agent + per workflow), live cost/status via `assign_async`, thinking-pane routing, system_logs view, reconnect/backfill hardening, LiveDashboard metrics + cost/error alerting (§13), OrphanReaper verified across crash scenarios, secret-redaction verified end-to-end.
- Acceptance: a multi-agent/multi-workflow run renders correctly under load with flat LiveView memory (streams), correct cost rollups, and clean reconnects; killing the BEAM and restarting reaps all orphaned children via the ledger; no secret ever appears in `agent_logs`/`system_logs`/logs.

---

## 13. Testing & Injection Strategy

- **ExUnit** throughout; `async: true` wherever no global state is shared.
- **FakeHarness** (`RepoBuilder.Harness.Fake`): a real mandatory-`@behaviour` implementation that emits a deterministic canned sequence of **canonical** events — drives session/workflow tests without spawning a CLI.
- **Mox + the registry as the single injection seam.** `Mox.defmock(RepoBuilder.Harness.Mock, for: RepoBuilder.Harness)`. **Inject by overriding the registry map**, NOT a separate `:harness_adapter` key — the runtime only ever resolves adapters through `RepoBuilder.Harness.Registry.fetch/1` (§10), so a separate key would never be consulted. In `test_helper.exs` / per-test setup:

  ```elixir
  # Override the entry for the harness under test so Registry.fetch/1 returns the mock.
  base = Application.fetch_env!(:repo_builder, :harnesses)
  Application.put_env(:repo_builder, :harnesses,
    Map.put(base, "claude", %{module: RepoBuilder.Harness.Mock, exe: "claude", default_model: nil, price_table: %{}}))
  ```

  This also supports running **Claude AND pi concurrently** in one test by overriding only the keys you need — a single global `:harness_adapter` could not. `import Mox` + `setup :verify_on_exit!` (without it, unmet `expect/3` pass silently). For calls made from a spawned Task/GenServer (the session server), use `Mox.allow/3` in `async: true` tests; reserve `set_mox_global` for `async: false`.
- **Normalizer property/boundary tests:** feed malformed JSON, partial lines split across chunks, multibyte chars split across chunks, unknown frame types, both casing styles, all three pi usage shapes, and the zai/GLM no-`agent_end` clean-exit case. Assert: never raises, correct `:skip`, correct canonical mapping. Use TypeCheck-derived generators or hand-written fixtures from real Claude/pi captures.
- **Supervision / crash-isolation tests:** start two sessions; crash one (`Process.exit(pid, :kill)`); assert the other keeps streaming and the crashed one is not auto-restarted (`:temporary`). For workflows, fail one step and assert the failure follows `on_failure` and does not affect a second concurrent workflow run. Verify OrphanReaper kills a deliberately leaked, **marked** OS child on boot and leaves an unmarked/recycled pid untouched (check `ps`).
- **Persistence tests:** round-trip Enum + JSONB; assert contexts return `{:error, changeset}` (not raw Postgrex) when constraints fire — proving the index/FK exists; assert `cost_usd` nil persists as `NULL` and `0.0` as `0`.
- **Secret-redaction tests:** assert a `raw` frame containing an API key is scrubbed in the persisted `agent_logs.payload` but present in the broadcast event.
- **Oban tests:** use Oban's testing mode; assert jobs are enqueued from webhook/cron, that never-valid args return `{:cancel, _}` (no retry storm), that unique-job dedup works (`unique: [fields: [:worker, :args], keys: [:workflow_run_id, :step_name], period: :infinity, states: [:available, :scheduled, :executing]]` on `StepWorker`; an analogous unique key on cron/webhook trigger workers keyed by trigger id + window), and that an invalid/unsigned webhook payload never becomes a poison job.
- **Webhook auth tests:** assert signature/HMAC verification + timestamp window (replay) rejection.

---

## 14. Concrete Setup Commands

```bash
# 0. Toolchain (pin the install-script default pair)
curl -fsSO https://elixir-lang.org/install.sh && sh install.sh elixir@1.20.1 otp@28.4

# 1. Phoenix installer + generate the app (typed, Postgres, UUID keys, trimmed, single app).
#    KEEP LiveView + LiveDashboard (do NOT pass --no-live / --no-dashboard) for observability.
mix archive.install hex phx_new
mix phx.new repo_builder --database postgres --binary-id --no-mailer --no-gettext

cd repo_builder   # (run subsequent mix tasks from the project root)
```

Add to `mix.exs` `deps/0`:

```elixir
{:phoenix, "~> 1.8.8"},
{:phoenix_live_view, "~> 1.2"},
{:ecto_sql, "~> 3.14"},
{:postgrex, ">= 0.0.0"},
{:jason, "~> 1.4"},                # verify latest 1.4.x on hex.pm
{:erlexec, "~> 2.0"},             # verify lockfile resolves to 2.3.4 (avoid retired 2.3.0–2.3.3)
{:muontrap, "~> 1.8"},            # containment alternative / hard-SIGKILL subtree path
{:oban, "~> 2.23"},
{:typedstruct, "~> 0.5", runtime: false},
{:type_check, "~> 0.13.7"},
{:mox, "~> 1.2", only: :test},
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}   # verify latest 1.7.x on hex.pm
# {:tz, "~> VERSION"}              # ONLY if Oban cron uses a non-UTC :timezone — pin latest from hex.pm
```

Wire `mix.exs` `project/0` with `elixir: "~> 1.20"`, `elixirc_options: [warnings_as_errors: true]`, and the `dialyzer: dialyzer()` block from §3.

```bash
# 2. Fetch + DB setup
mix deps.get
mix ecto.create

# 3. Oban migration + config
mix ecto.gen.migration add_oban_jobs   # body: use Oban.Migration; def up, do: Oban.Migration.up();
                                        #                            def down, do: Oban.Migration.down()
#   NOTE: Oban's tables use bigint job ids — do NOT force binary_id onto them (§8).
# config/config.exs:
#   config :repo_builder, Oban,
#     repo: RepoBuilder.Repo,
#     queues: [default: 10, sessions: 20, workflows: 10],
#     plugins: [{Oban.Plugins.Cron, crontab: [], timezone: "Etc/UTC"}]
# Add {Oban, Application.fetch_env!(:repo_builder, Oban)} to the supervision tree (§5).

mix ecto.migrate

# 4. Dialyzer PLT (build separately so CI caches it cleanly; gitignore priv/plts/*.plt[.hash])
mkdir -p priv/plts
mix dialyzer --plt
mix dialyzer --format github --list-unused-filters

# 5. Run
mix phx.server
```

> Generator flag notes: default DB is `postgres`; `--binary-id` gives UUID PKs; `--no-mailer`/`--no-gettext` trim unused pieces; default adapter is **bandit** (do not pass `--adapter cowboy` unless you need Cowboy). Do **not** pass `--no-live`, `--no-dashboard`, or `--no-esbuild` — they strip exactly the assets/LiveView the dashboard needs.

---

## 15. Acceptance Criteria ("done") + References

### "Done" criteria

1. CRUD of agents and workflows works through `@spec`'d contexts; the web layer never touches `Repo` directly.
2. A live session GenServer drives a **real** Claude CLI and a **real** pi CLI, normalizing each to the **identical canonical event contract**; the dashboard streams both live.
3. Interrupting/crashing a session reaps its OS child with **zero orphans** (SIGTERM→SIGKILL); after a hard BEAM kill, `OrphanReaper` reaps marked orphans on boot via the durable `os_pid_ledger` (verified by marker, never by bare pid).
4. Crash isolation holds: one agent or one workflow step failing affects only itself.
5. An ADW (`plan → build → review → fix`) runs end-to-end with deterministic edges and harness-delegated steps; a failed step follows `on_failure` and is isolated.
6. Oban durably triggers workflows via **signature-verified webhook** and **cron**, surviving a node restart (resumes from `workflow_runs.current_step`); live streaming stays in GenServers (the durable/live split is honored); unique-job dedup prevents double-runs.
7. The **same ADW** runs under both harnesses by changing only the `harness` string; **adding a third harness is one adapter module + one config entry** (no edits to `Event`/`Agent`/runtime).
8. The LiveView dashboard renders swimlanes + append-only logs via **streams** (flat memory), live cost/status via `assign_async`, and resumes correctly on reconnect by seeding from persisted rows.
9. No secret (API keys / provider creds) appears in `agent_logs`, `system_logs`, or any log; the persisted `raw` is redacted while the live event keeps full detail.
10. Live-session concurrency is bounded (admission gate + `max_children`); the node does not exhaust OS processes/fds under many concurrent sessions.
11. CI is green: `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix dialyzer` (no stale ignore filters). Every public function has an `@spec` (callback implementations exempt, §3 rule 1); every struct is typed with `@enforce_keys`; a minimal adapter (`command/1` + `normalize/2` only) compiles clean; untrusted harness JSON is validated at the boundary before becoming a canonical event.

### References (citation URLs from the research)

- Elixir / types / Dialyzer: https://elixir-lang.org/install.html · https://hexdocs.pm/elixir/changelog.html · https://hexdocs.pm/elixir/gradual-set-theoretic-types.html · https://hexdocs.pm/elixir/compatibility-and-deprecations.html · https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/ · https://hex.pm/packages/dialyxir · https://github.com/erlang/otp/releases
- Phoenix / PubSub: https://hex.pm/packages/phoenix · https://hex.pm/packages/phoenix_pubsub · https://hexdocs.pm/phoenix/overview.html · https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html · https://hexdocs.pm/phoenix/directory_structure.html · https://hexdocs.pm/phoenix/contexts.html · https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html
- LiveView: https://hex.pm/packages/phoenix_live_view · https://hexdocs.pm/phoenix_live_view/welcome.html · https://hexdocs.pm/phoenix_live_view/assigns-eex.html · https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html · https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.AsyncResult.html
- Ecto / Postgres: https://hex.pm/packages/ecto · https://hex.pm/packages/ecto_sql · https://hex.pm/packages/postgrex · https://ecto.hexdocs.pm/Ecto.Schema.html · https://ecto.hexdocs.pm/Ecto.Enum.html · https://ecto.hexdocs.pm/Ecto.Changeset.html
- OS-process libs: https://hex.pm/packages/muontrap · https://hex.pm/packages/erlexec · https://hexdocs.pm/elixir/Port.html · https://hexdocs.pm/erlexec/readme.html · https://github.com/saleyn/erlexec
- Oban: https://hex.pm/packages/oban · https://hexdocs.pm/oban/Oban.Worker.html · https://hexdocs.pm/oban/Oban.Plugins.Cron.html · https://hexdocs.pm/oban/Oban.Telemetry.html · https://hexdocs.pm/oban/unique_jobs.html
- Typed structs / TypeCheck / Mox: https://hex.pm/packages/typedstruct · https://github.com/saleyn/typedstruct · https://hex.pm/packages/type_check · https://hexdocs.pm/type_check/TypeCheck.html · https://hex.pm/packages/mox
- Harness wire formats: https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/cli-reference · https://code.claude.com/docs/en/agent-sdk/python · https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode
