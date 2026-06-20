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
          orchestrator_id: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          archived: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :harness, :string
    field :provider, Ecto.Enum, values: [:anthropic, :openai, :local]
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :config, :map, default: %{}
    # Additive worker-ownership/resume fields (§8). `orchestrator_id` ties a worker
    # to the orchestrator that spawned it; `session_id` resumes its CLI session.
    field :orchestrator_id, :binary_id
    field :session_id, :string
    field :model, :string
    field :system_prompt, :string
    # Soft-archive (issue agent-CRUD): an archived agent is hidden from the default
    # rail/list but its row + `agent_logs`/cost history are preserved (vs hard delete).
    field :archived, :boolean, default: false
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

  @doc """
  Changeset for an orchestrator-owned worker. Casts the additive ownership/resume
  fields; `harness` stays OPEN (validated against the live registry, §10). Name is
  unique PER orchestrator (partial global unique still guards manual agents).
  """
  @spec worker_changeset(t(), map()) :: Ecto.Changeset.t()
  def worker_changeset(agent, params) do
    agent
    |> cast(params, [
      :name,
      :harness,
      :provider,
      :status,
      :config,
      :orchestrator_id,
      :session_id,
      :model,
      :system_prompt
    ])
    |> validate_required([:name, :harness, :orchestrator_id])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:harness, Registry.known(), message: "is not a registered harness")
    # Report the composite `(orchestrator_id, name)` violation on `:name` (still keyed to
    # the same index) so the duplicate is surfaced as an actionable "duplicate name" — not
    # a misleading `orchestrator_id has already been taken`. A bare field attaches the
    # error to that field while still matching the named composite index.
    |> unique_constraint(:name, name: :agents_orchestrator_id_name_index)
  end

  @doc "Set a worker's resumable CLI session id."
  @spec session_changeset(t(), String.t() | nil) :: Ecto.Changeset.t()
  def session_changeset(agent, session_id) do
    change(agent, session_id: session_id)
  end

  @doc "Soft-archive changeset: flips `archived` to true, preserving log/cost history."
  @spec archive_changeset(t()) :: Ecto.Changeset.t()
  def archive_changeset(agent) do
    change(agent, archived: true)
  end
end
