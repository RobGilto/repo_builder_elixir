defmodule RepoBuilder.Plugins.Plugin do
  @moduledoc """
  An installed plugin — the durable record of a `<plugin_id>@<version>` package
  unpacked under `agentic_plugins/` (the agentic plugin system foundation).

  `status` is a closed `Ecto.Enum`; `plugin_id` is an OPEN string identity (like a
  harness key, §10). The decoded `manifest` is stored as JSONB; rehydrate it through
  `RepoBuilder.Plugins.Manifest.from_map/1` (JSONB loads with string keys).
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type status :: :installed | :disabled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          plugin_id: String.t() | nil,
          version: String.t() | nil,
          source: String.t() | nil,
          install_path: String.t() | nil,
          manifest: map(),
          checksum: String.t() | nil,
          status: status(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @statuses ~w(installed disabled)a

  schema "plugins" do
    field :plugin_id, :string
    field :version, :string
    field :source, :string
    field :install_path, :string
    field :manifest, :map, default: %{}
    field :checksum, :string
    field :status, Ecto.Enum, values: @statuses, default: :installed
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(plugin, params) do
    plugin
    |> cast(params, [:plugin_id, :version, :source, :install_path, :manifest, :checksum, :status])
    |> validate_required([:plugin_id, :version, :install_path])
    |> unique_constraint([:plugin_id, :version],
      name: :plugins_plugin_id_version_index,
      message: "is already installed at this version"
    )
  end
end
