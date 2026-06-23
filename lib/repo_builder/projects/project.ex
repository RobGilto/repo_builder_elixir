defmodule RepoBuilder.Projects.Project do
  @moduledoc """
  A first-class target repository the platform adapts to (the agentic-layer adaptor
  seam). Promotes the orchestrator's bare `working_dir` string to a durable entity
  carrying per-repo identity, defaults, an auto-detected capability map, a pinned
  command pack, an isolation mode, and a primed orchestrator context.

  `default_harness` is a validated `:string` (open identity, §10) — NOT a closed
  `Ecto.Enum` — checked at the write boundary against the live registry, mirroring
  `Agents.Agent`. `isolation_mode`/`status` are closed `Ecto.Enum`s. A `nil`
  `project_id` on `agents`/`workflow_runs` means "the platform itself" — today's
  back-compatible default.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Harness.Registry

  @type isolation_mode :: :direct | :worktree
  @type status :: :active | :archived

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          root_path: String.t() | nil,
          git_remote: String.t() | nil,
          default_branch: String.t() | nil,
          stack: map(),
          capabilities: map(),
          command_pack: String.t(),
          command_pack_version: String.t(),
          default_harness: String.t() | nil,
          default_model_tier: String.t() | nil,
          budget_cap_usd: Decimal.t() | nil,
          isolation_mode: isolation_mode(),
          context_primer: String.t() | nil,
          status: status(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @isolation_modes ~w(direct worktree)a
  @statuses ~w(active archived)a

  schema "projects" do
    field :name, :string
    field :root_path, :string
    field :git_remote, :string
    field :default_branch, :string
    # Detected stack descriptor (language, build tool, marker files) — Profiler (Phase 2).
    field :stack, :map, default: %{}
    # Resolved capability token values (test/build/lint/... commands, dirs) — Phase 2/3.
    field :capabilities, :map, default: %{}
    # Command-pack pinning (Phase 3): "auto" = match detected stack, "latest" = newest.
    field :command_pack, :string, default: "auto"
    field :command_pack_version, :string, default: "latest"
    # Open harness identity, validated vs the registry at the changeset boundary.
    field :default_harness, :string
    field :default_model_tier, :string
    field :budget_cap_usd, :decimal
    field :isolation_mode, Ecto.Enum, values: @isolation_modes, default: :direct
    field :context_primer, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    timestamps()
  end

  @doc """
  Changeset for create/update. Requires `name` + `root_path`; validates the open
  `default_harness` against the live registry (when provided) and enforces a unique
  project name.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, params) do
    project
    |> cast(params, [
      :name,
      :root_path,
      :git_remote,
      :default_branch,
      :stack,
      :capabilities,
      :command_pack,
      :command_pack_version,
      :default_harness,
      :default_model_tier,
      :budget_cap_usd,
      :isolation_mode,
      :context_primer,
      :status
    ])
    |> validate_required([:name, :root_path])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_harness()
    |> validate_number(:budget_cap_usd, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end

  # `default_harness` is optional, but when present it must be a registered harness
  # (open identity validated at the boundary, like `Agents.Agent`).
  @spec validate_harness(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_harness(changeset) do
    case get_field(changeset, :default_harness) do
      nil ->
        changeset

      "" ->
        changeset

      _harness ->
        validate_inclusion(changeset, :default_harness, Registry.known(),
          message: "is not a registered harness"
        )
    end
  end
end
