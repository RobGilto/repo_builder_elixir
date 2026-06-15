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
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          archived: boolean(),
          config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :harness, :string
    field :provider, Ecto.Enum, values: [:anthropic, :openai, :local]
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :model, :string
    field :system_prompt, :string
    field :archived, :boolean, default: false
    field :config, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(agent, params) do
    agent
    |> cast(params, [
      :name,
      :harness,
      :provider,
      :status,
      :model,
      :system_prompt,
      :archived,
      :config
    ])
    |> validate_required([:name, :harness, :provider])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:system_prompt, max: 20_000)
    |> validate_inclusion(:harness, Registry.known(), message: "is not a registered harness")
    |> unique_constraint(:name)
  end

  @doc "Soft-archive changeset: flips `archived` to true, preserving log/cost history."
  @spec archive_changeset(t()) :: Ecto.Changeset.t()
  def archive_changeset(agent) do
    change(agent, archived: true)
  end

  @spec status_changeset(t(), status()) :: Ecto.Changeset.t()
  def status_changeset(agent, status) do
    change(agent, status: status)
  end
end
