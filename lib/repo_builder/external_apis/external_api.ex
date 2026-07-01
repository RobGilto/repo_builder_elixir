defmodule RepoBuilder.ExternalApis.ExternalApi do
  @moduledoc """
  One registered external API / MCP provider
  (issue-external-api-mcp-provisioning). A `nil` `project_id` means the user/platform
  scope ("all orchestrators"); a concrete id means a single project's scope ("the
  project orchestrator"). Mirrors `RepoBuilder.Secrets.ProjectSecret`'s scoping.

  Open-identity / closed-contract (BUILD_PROMPT §10): `transport`/`auth_scheme`/`status`
  are closed `Ecto.Enum`s; `name`/`provider`/`url`/`secret_name` are open strings
  validated at the changeset boundary. The registration references a vault secret by
  `secret_name` — the literal token is NEVER stored on the row.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type transport :: :http | :sse | :stdio
  @type auth_scheme :: :none | :bearer | :header
  @type status :: :active | :disabled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          transport: transport() | nil,
          url: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          auth_scheme: auth_scheme(),
          auth_header: String.t() | nil,
          secret_name: String.t() | nil,
          description: String.t() | nil,
          instructions: String.t() | nil,
          doc_urls: [String.t()],
          allowed_tools: [String.t()],
          status: status(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @name_format ~r/^[a-z][a-z0-9_-]*$/
  @secret_format ~r/^[A-Z][A-Z0-9_]*$/

  @transports [:http, :sse, :stdio]
  @auth_schemes [:none, :bearer, :header]
  @statuses [:active, :disabled]

  schema "external_apis" do
    field :project_id, :binary_id
    field :name, :string
    field :provider, :string
    field :transport, Ecto.Enum, values: @transports
    field :url, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :auth_scheme, Ecto.Enum, values: @auth_schemes, default: :none
    field :auth_header, :string
    field :secret_name, :string
    field :description, :string
    field :instructions, :string
    field :doc_urls, {:array, :string}, default: []
    field :allowed_tools, {:array, :string}, default: []
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The closed transport set, for UI selects and validation."
  @spec transports() :: [transport()]
  def transports, do: Ecto.Enum.values(__MODULE__, :transport)

  @doc "The closed auth-scheme set, for UI selects and validation."
  @spec auth_schemes() :: [auth_scheme()]
  def auth_schemes, do: Ecto.Enum.values(__MODULE__, :auth_scheme)

  @doc """
  Changeset for register/edit. Closed enums validated by inclusion; conditional
  requirements: http/sse need a `url`, stdio needs a `command`; bearer/header need a
  `secret_name` in env-var shape. The token itself is never cast here.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(api, params) do
    api
    |> cast(params, [
      :project_id,
      :name,
      :provider,
      :transport,
      :url,
      :command,
      :args,
      :auth_scheme,
      :auth_header,
      :secret_name,
      :description,
      :instructions,
      :doc_urls,
      :allowed_tools,
      :status,
      :metadata
    ])
    |> update_change(:name, &trim_or_nil/1)
    |> validate_required([:name, :transport])
    |> validate_format(:name, @name_format,
      message: "must be a valid MCP server key (lowercase, digits, _ or -; leading letter)"
    )
    |> validate_length(:name, max: 128)
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:auth_scheme, @auth_schemes)
    |> validate_inclusion(:status, @statuses)
    |> validate_transport()
    |> validate_auth()
    |> unique_constraint(:name,
      name: :external_apis_project_name_index,
      message: "already registered for this project"
    )
    |> unique_constraint(:name,
      name: :external_apis_platform_name_index,
      message: "already registered for all orchestrators"
    )
  end

  # http/sse need a url; stdio needs a command (the connection detail per transport).
  @spec validate_transport(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_transport(changeset) do
    case get_field(changeset, :transport) do
      t when t in [:http, :sse] -> validate_required(changeset, [:url])
      :stdio -> validate_required(changeset, [:command])
      _other -> changeset
    end
  end

  # bearer/header reference a vault secret by name (env-var shape); none needs nothing.
  @spec validate_auth(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_auth(changeset) do
    case get_field(changeset, :auth_scheme) do
      scheme when scheme in [:bearer, :header] ->
        changeset
        |> validate_required([:secret_name])
        |> validate_format(:secret_name, @secret_format,
          message: "must be an env-var name (uppercase, digits, underscore; leading letter)"
        )

      _none ->
        changeset
    end
  end

  @spec trim_or_nil(String.t() | nil) :: String.t() | nil
  defp trim_or_nil(value) when is_binary(value), do: String.trim(value)
  defp trim_or_nil(value), do: value
end
