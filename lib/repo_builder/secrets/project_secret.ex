defmodule RepoBuilder.Secrets.ProjectSecret do
  @moduledoc """
  One encrypted-at-rest secret in a project's vault
  (issue-per-project-encrypted-secrets-vault). A `nil` `project_id` means "the
  platform itself" (the back-compatible §8 convention).

  `name` is the env-var the orchestrator references and the OS env key injected into a
  worker child, so it is validated to the env-var shape `~r/^[A-Z][A-Z0-9_]*$/`.
  `ciphertext` is the Base64 AES-256-GCM blob (`RepoBuilder.Secrets.Cipher`); `last_four`
  is the masked UI hint only — never the value. `ciphertext` is dropped from the struct's
  printable form via `@derive {Inspect, except: [:ciphertext]}` so an accidental `inspect`
  never dumps it.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          ciphertext: String.t() | nil,
          last_four: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @name_format ~r/^[A-Z][A-Z0-9_]*$/

  @derive {Inspect, except: [:ciphertext]}
  schema "project_secrets" do
    field :project_id, :binary_id
    field :name, :string
    field :ciphertext, :string
    field :last_four, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for an upsert (`put_secret/3`): name shape + ciphertext presence."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(secret, params) do
    secret
    |> cast(params, [:project_id, :name, :ciphertext, :last_four])
    |> validate_required([:name, :ciphertext])
    |> update_change(:name, &String.trim/1)
    |> validate_format(:name, @name_format,
      message: "must be an env-var name (uppercase, digits, underscore; leading letter)"
    )
    |> validate_length(:name, max: 128)
    |> unique_constraint(:name,
      name: :project_secrets_project_name_index,
      message: "already set for this project"
    )
    |> unique_constraint(:name,
      name: :project_secrets_platform_name_index,
      message: "already set for the platform"
    )
  end
end
