defmodule RepoBuilder.Orchestrator.Orchestrator do
  @moduledoc """
  Durable orchestrator identity (BUILD_PROMPT.md §3/§8).

  An orchestrator is "just another harness session" with `role: :orchestrator`:
  it carries a resumable CLI `session_id`, a per-orchestrator bearer-token hash
  scoping its MCP tool surface, and a running cost total. `harness` is a validated
  `:string` (open identity, §10) — NOT a closed enum — enforced at the write
  boundary via `validate_inclusion/3` against the live registry; `status` is a
  closed `Ecto.Enum`.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Harness.Registry

  @type status :: :idle | :running | :error

  @typedoc """
  How the orchestrator's system prompt is applied to the harness CLI: `:append`
  adds it onto the harness default (`--append-system-prompt`); `:replace` swaps the
  default out entirely (`--system-prompt`).
  """
  @type mode :: :append | :replace

  @typedoc """
  Harness-blind reasoning effort. Each orchestrator-capable adapter maps it to its
  own CLI flag (Claude `--effort`, pi `--thinking`); `:default` means "omit the flag"
  (use the harness's own default — zero regression). `:max` is the single "think as
  hard as possible" intent (Claude `max`, pi `xhigh`).
  """
  @type effort :: :default | :off | :low | :medium | :high | :max

  # Single source of truth for the effort enum, shared by the schema field, the
  # changeset validation, and the context's `reasoning_efforts/0` (UI ordering).
  @efforts [:default, :off, :low, :medium, :high, :max]

  @doc "The ordered reasoning-effort levels (`:default` first)."
  @spec efforts() :: [effort(), ...]
  def efforts, do: @efforts

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          harness: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          session_id: String.t() | nil,
          system_prompt: String.t() | nil,
          system_prompt_mode: mode(),
          reasoning_effort: effort(),
          status: status(),
          working_dir: String.t() | nil,
          total_cost_usd: Decimal.t(),
          estimated_cost_usd: Decimal.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          context_tokens: non_neg_integer(),
          token_hash: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "orchestrators" do
    field :name, :string
    field :harness, :string
    # Open provider identity (§10/§3-rule-5) — pi supports 30+ providers, so this is
    # a loosely-validated :string, NOT a closed Ecto.Enum.
    field :provider, :string
    field :model, :string
    field :session_id, :string
    field :system_prompt, :string
    field :system_prompt_mode, Ecto.Enum, values: [:append, :replace], default: :append
    field :reasoning_effort, Ecto.Enum, values: @efforts, default: :default
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :working_dir, :string
    field :total_cost_usd, :decimal, default: Decimal.new(0)
    # Token-derived live ESTIMATE (display-only, OVERWRITE-latest snapshot — NOT a sum);
    # nullable (nil = unpriced/no estimate yet). Superseded by `total_cost_usd` when the
    # harness reports the authoritative billed amount on the terminal event.
    field :estimated_cost_usd, :decimal
    # Cumulative lifetime token throughput (cost report); `context_tokens` is the
    # LATEST turn's input+output (context-window occupancy), overwritten each turn.
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :context_tokens, :integer, default: 0
    field :token_hash, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(orchestrator, params) do
    orchestrator
    |> cast(params, [
      :name,
      :harness,
      :provider,
      :model,
      :session_id,
      :system_prompt,
      :system_prompt_mode,
      :reasoning_effort,
      :status,
      :working_dir,
      :total_cost_usd,
      :estimated_cost_usd,
      :input_tokens,
      :output_tokens,
      :context_tokens,
      :token_hash,
      :metadata
    ])
    |> validate_required([:name, :harness])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:context_tokens, greater_than_or_equal_to: 0)
    # Defensive: the Ecto.Enum already constrains the column, but an explicit
    # inclusion gives a friendly changeset error on bad input.
    |> validate_inclusion(:system_prompt_mode, [:append, :replace])
    |> validate_inclusion(:reasoning_effort, @efforts)
    # Bound textarea input so an operator can't persist an unbounded blob.
    |> validate_length(:system_prompt, max: 100_000)
    |> validate_inclusion(:harness, Registry.known(), message: "is not a registered harness")
    # Open identity: a present provider must be non-empty, but membership is NOT
    # constrained (pi providers are open) — mirrors the harness looseness (§3 rule 5).
    |> validate_length(:provider, min: 1)
    |> unique_constraint(:name)
  end
end
