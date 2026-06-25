defmodule RepoBuilder.Secrets do
  @moduledoc """
  Context for the per-project encrypted secrets vault
  (issue-per-project-encrypted-secrets-vault). The ONLY `Repo` caller for
  `project_secrets` (BUILD_PROMPT.md §8). Every public function is `@spec`'d and total.

  The operator deposits a plaintext value (UI write path); it is AES-256-GCM encrypted
  at rest (`RepoBuilder.Secrets.Cipher`) and decrypted JUST-IN-TIME only at the
  OS-child env boundary (`resolve_env/1`) and the value-scrubbing seam
  (`active_values/1`). `list_names/1` — what the UI and the orchestrator system prompt
  consume — NEVER returns plaintext or ciphertext.

  Fail-closed: with no `SECRETS_KEY` configured, `put_secret/3` surfaces a clear
  changeset error and the decrypt paths return empty (`%{}` / `[]`), so dev without
  secrets is unaffected.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Repo
  alias RepoBuilder.Secrets.{Cipher, ProjectSecret}

  require Logger

  @typedoc "A masked secret row for the UI / system prompt — never carries the value."
  @type name_entry :: %{name: String.t(), last_four: String.t() | nil, updated_at: DateTime.t()}

  @doc """
  Encrypt `plaintext` and upsert it under `(project_id, name)` — rotation overwrites the
  existing row. Returns `{:error, changeset}` on a bad name or when no master key is
  configured (fail-closed).
  """
  @spec put_secret(Ecto.UUID.t() | nil, String.t(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, Ecto.Changeset.t()}
  def put_secret(project_id, name, plaintext)
      when is_binary(name) and is_binary(plaintext) do
    case Cipher.encrypt(plaintext) do
      {:ok, ciphertext} ->
        params = %{
          "project_id" => project_id,
          "name" => name,
          "ciphertext" => ciphertext,
          "last_four" => last_four(plaintext)
        }

        get_existing(project_id, name)
        |> ProjectSecret.changeset(params)
        |> Repo.insert_or_update()

      {:error, reason} ->
        {:error, key_error_changeset(name, reason)}
    end
  end

  @doc """
  The masked rows for `project_id` (name + last_four + updated_at), name-sorted. This is
  the ONLY read the UI and the system prompt use — it NEVER returns plaintext or
  ciphertext.
  """
  @spec list_names(Ecto.UUID.t() | nil) :: [name_entry()]
  def list_names(project_id) do
    project_id
    |> scope_query()
    |> from(order_by: [asc: :name], select: [:name, :last_four, :updated_at])
    |> Repo.all()
    |> Enum.map(fn s -> %{name: s.name, last_four: s.last_four, updated_at: s.updated_at} end)
  end

  @doc "Delete the secret `name` from `project_id`'s vault (no-op if absent)."
  @spec delete_secret(Ecto.UUID.t() | nil, String.t()) :: :ok
  def delete_secret(project_id, name) when is_binary(name) do
    _ =
      project_id
      |> scope_query()
      |> from(where: [name: ^name])
      |> Repo.delete_all()

    :ok
  end

  @doc """
  Decrypt EVERY secret for `project_id` into a `name => value` env map — the single
  decrypt-into-plaintext call site, invoked only from the injection seam. Returns `%{}`
  for a `nil`/unknown project or when the key is unset (fail-closed, logged once).
  """
  @spec resolve_env(Ecto.UUID.t() | nil) :: %{optional(String.t()) => String.t()}
  def resolve_env(nil), do: %{}

  def resolve_env(project_id) do
    project_id
    |> load_rows()
    |> Enum.reduce(%{}, fn row, acc ->
      case Cipher.decrypt(row.ciphertext) do
        {:ok, value} ->
          Map.put(acc, row.name, value)

        {:error, reason} ->
          log_decrypt_failure(reason, row.name)
          acc
      end
    end)
  end

  @doc """
  The plaintext VALUES for `project_id` — the scrub set for value-based redaction. Also
  decrypt-gated; used only inside the redaction seam. Empty for a `nil`/unknown project
  or an unset key.
  """
  @spec active_values(Ecto.UUID.t() | nil) :: [String.t()]
  def active_values(project_id) do
    project_id
    |> resolve_env()
    |> Map.values()
  end

  # --- internals ---

  @spec get_existing(Ecto.UUID.t() | nil, String.t()) :: ProjectSecret.t()
  defp get_existing(project_id, name) do
    project_id
    |> scope_query()
    |> from(where: [name: ^name])
    |> Repo.one() || %ProjectSecret{}
  end

  @spec load_rows(Ecto.UUID.t() | nil) :: [ProjectSecret.t()]
  defp load_rows(project_id) do
    project_id
    |> scope_query()
    |> Repo.all()
  end

  # Scope to a concrete project id, or to the platform (NULL) rows when nil — the
  # back-compatible "the platform itself" convention. Returns a base query.
  @spec scope_query(Ecto.UUID.t() | nil) :: Ecto.Query.t()
  defp scope_query(nil), do: from(s in ProjectSecret, where: is_nil(s.project_id))
  defp scope_query(project_id), do: from(s in ProjectSecret, where: s.project_id == ^project_id)

  @spec last_four(String.t()) :: String.t() | nil
  defp last_four(plaintext) when byte_size(plaintext) >= 4,
    do: String.slice(plaintext, -4, 4)

  defp last_four(_plaintext), do: nil

  # Surface a cipher key failure as a name-field changeset error so the UI shows a clear
  # message instead of a crash (fail-closed when SECRETS_KEY is unset/misconfigured).
  @spec key_error_changeset(String.t(), Cipher.reason()) :: Ecto.Changeset.t()
  defp key_error_changeset(name, reason) do
    %ProjectSecret{}
    |> ProjectSecret.changeset(%{"name" => name, "ciphertext" => "x"})
    |> Ecto.Changeset.add_error(:value, key_error_message(reason))
    |> Map.put(:action, :insert)
  end

  @spec key_error_message(Cipher.reason()) :: String.t()
  defp key_error_message(:no_key),
    do: "secrets vault is not configured (set the SECRETS_KEY env var to enable it)"

  defp key_error_message(:bad_key),
    do: "SECRETS_KEY is misconfigured (expected base64 of 32 random bytes)"

  defp key_error_message(_reason), do: "could not encrypt the secret value"

  @spec log_decrypt_failure(Cipher.reason(), String.t()) :: :ok
  defp log_decrypt_failure(:no_key, _name) do
    Logger.warning(
      "project secrets present but SECRETS_KEY is unset — vault disabled (fail-closed)"
    )

    :ok
  end

  defp log_decrypt_failure(reason, name) do
    Logger.warning("failed to decrypt project secret #{name}: #{inspect(reason)}")
    :ok
  end
end
