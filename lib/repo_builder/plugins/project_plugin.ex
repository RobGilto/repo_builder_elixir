defmodule RepoBuilder.Plugins.ProjectPlugin do
  @moduledoc """
  Per-project plugin activation (the agentic plugin system foundation). Joins an
  installed plugin to a project; a NULLABLE `project_id` means "the platform itself"
  (the back-compatible default). The set of `enabled` rows for a project, ordered by
  `priority`, drives the effective contribution set (`Plugins.Activation`).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          plugin_id: String.t() | nil,
          version: String.t() | nil,
          enabled: boolean(),
          priority: integer(),
          config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_plugins" do
    field :project_id, :binary_id
    field :plugin_id, :string
    field :version, :string
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :config, :map, default: %{}
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(activation, params) do
    activation
    |> cast(params, [:project_id, :plugin_id, :version, :enabled, :priority, :config])
    |> validate_required([:plugin_id])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :plugin_id],
      name: :project_plugins_project_plugin_index,
      message: "is already activated for this project"
    )
    |> unique_constraint(:plugin_id,
      name: :project_plugins_platform_plugin_index,
      message: "is already activated for the platform"
    )
  end
end
