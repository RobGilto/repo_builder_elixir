defmodule RepoBuilder.Agents.Agent do
  @moduledoc """
  Durable agent definition (BUILD_PROMPT.md §3/§8).

  `harness` is a validated `:string` (open identity, §10) — NOT a closed
  `Ecto.Enum` — enforced at the write boundary via `validate_inclusion/3` against
  the live registry. `provider`/`status` are closed `Ecto.Enum`s.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Harness.Registry

  @type provider :: :anthropic | :openai | :local
  @type status :: :idle | :running | :error

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          harness: String.t() | nil,
          provider: provider() | nil,
          status: status(),
          config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :harness, :string
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
    |> validate_inclusion(:harness, Registry.known(), message: "is not a registered harness")
    |> unique_constraint(:name)
  end

  @spec status_changeset(t(), status()) :: Ecto.Changeset.t()
  def status_changeset(agent, status) do
    change(agent, status: status)
  end
end
