defmodule RepoBuilder.Secrets.Cipher do
  @moduledoc """
  Hand-rolled AES-256-GCM for the per-project secrets vault
  (issue-per-project-encrypted-secrets-vault). Pure — no `Repo`, no process state.

  Wire format (the raw stored bytes, before Base64 for the DB column):

      <<iv::96, tag::128, ciphertext::binary>>

  A fresh 12-byte IV is drawn per `encrypt/1` (`:crypto.strong_rand_bytes/1`); the
  GCM auth tag is 16 bytes; AAD is empty. The 32-byte master key comes from the
  runtime config `:repo_builder, RepoBuilder.Secrets, key: <base64>` (sourced from the
  `SECRETS_KEY` env var in `config/runtime.exs`).

  **Fail-closed:** with no key configured both `encrypt/1` and `decrypt/1` return
  `{:error, :no_key}` — dev without secrets is unaffected, mirroring the
  `WEBHOOK_SECRET`-when-unset precedent. Every function is total over bad input and
  returns a tagged tuple — it NEVER raises (`ai_docs/typed-elixir-standard.md`).
  """

  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @type reason :: :no_key | :bad_key | :invalid

  @doc """
  Encrypt `plaintext` into the Base64 wire blob suitable for the DB column.

  Returns `{:error, :no_key}` when no master key is configured, `{:error, :bad_key}`
  when the configured key is not 32 raw bytes, and never raises.
  """
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, reason()}
  def encrypt(plaintext) when is_binary(plaintext) do
    with {:ok, key} <- master_key() do
      iv = :crypto.strong_rand_bytes(@iv_bytes)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, @tag_bytes, true)

      {:ok, Base.encode64(iv <> tag <> ciphertext)}
    end
  rescue
    _error -> {:error, :invalid}
  catch
    _kind, _value -> {:error, :invalid}
  end

  @doc """
  Decrypt the Base64 wire `blob` produced by `encrypt/1` back to plaintext.

  Returns `{:error, :no_key}` with no key configured, `{:error, :invalid}` for a
  tampered/malformed blob (the GCM tag check fails), and never raises.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, reason()}
  def decrypt(blob) when is_binary(blob) do
    with {:ok, key} <- master_key(),
         {:ok, raw} <- decode64(blob),
         {:ok, {iv, tag, ciphertext}} <- split(raw) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :invalid}
      end
    end
  rescue
    _error -> {:error, :invalid}
  catch
    _kind, _value -> {:error, :invalid}
  end

  @doc "True when a usable 32-byte master key is configured (drives fail-closed UI/boot copy)."
  @spec key_present?() :: boolean()
  def key_present? do
    match?({:ok, _key}, master_key())
  end

  @spec master_key() :: {:ok, binary()} | {:error, :no_key | :bad_key}
  defp master_key do
    case Application.get_env(:repo_builder, RepoBuilder.Secrets, [])[:key] do
      value when is_binary(value) and value != "" ->
        case Base.decode64(value) do
          {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
          _other -> {:error, :bad_key}
        end

      _absent ->
        {:error, :no_key}
    end
  end

  @spec decode64(binary()) :: {:ok, binary()} | {:error, :invalid}
  defp decode64(blob) do
    case Base.decode64(blob) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid}
    end
  end

  @spec split(binary()) ::
          {:ok, {<<_::96>>, <<_::128>>, binary()}} | {:error, :invalid}
  defp split(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>),
    do: {:ok, {iv, tag, ciphertext}}

  defp split(_raw), do: {:error, :invalid}
end
