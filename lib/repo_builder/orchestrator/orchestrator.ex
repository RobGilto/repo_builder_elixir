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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          harness: String.t() | nil,
          model: String.t() | nil,
          session_id: String.t() | nil,
          system_prompt: String.t() | nil,
          status: status(),
          working_dir: String.t() | nil,
          total_cost_usd: Decimal.t(),
          token_hash: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "orchestrators" do
    field :name, :string
    field :harness, :string
    field :model, :string
    field :session_id, :string
    field :system_prompt, :string
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :working_dir, :string
    field :total_cost_usd, :decimal, default: Decimal.new(0)
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
      :model,
      :session_id,
      :system_prompt,
      :status,
      :working_dir,
      :total_cost_usd,
      :token_hash,
      :metadata
    ])
    |> validate_required([:name, :harness])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:harness, Registry.known(), message: "is not a registered harness")
    |> unique_constraint(:name)
  end
end
