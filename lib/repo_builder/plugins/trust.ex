defmodule RepoBuilder.Plugins.Trust do
  @moduledoc """
  The install trust gate (the agentic plugin system foundation). Verifies a staged
  package against the configured policy (`RepoBuilder.Plugins.Registry.trust/0`)
  BEFORE it is unpacked and recorded:

    * `allow_code: false`     — refuse any code-bearing plugin (`:code_not_allowed`)
    * `require_checksum: true` — the manifest `checksum` must match the package digest
    * `require_signature: true` — reserved hook (`:unsigned` until a scheme exists)

  Code plugins execute arbitrary BEAM code in-node — there is no real sandbox — so the
  remote store NEVER auto-installs one without operator confirmation. The checksum is a
  content digest over every package file except `plugin.json` itself.
  """
  alias RepoBuilder.Plugins.{Manifest, Registry}

  @type reason :: :checksum_mismatch | :code_not_allowed | :unsigned

  @doc "Verify a staged package dir against the trust policy."
  @spec verify(Manifest.t(), String.t()) :: :ok | {:error, reason()}
  def verify(%Manifest{} = manifest, dir) do
    policy = Registry.trust()

    with :ok <- verify_code(manifest, policy),
         :ok <- verify_checksum(manifest, dir, policy) do
      verify_signature(manifest, policy)
    end
  end

  @spec verify_code(Manifest.t(), map()) :: :ok | {:error, :code_not_allowed}
  defp verify_code(manifest, %{allow_code: false}) do
    if Manifest.code?(manifest), do: {:error, :code_not_allowed}, else: :ok
  end

  defp verify_code(_manifest, _policy), do: :ok

  @spec verify_checksum(Manifest.t(), String.t(), map()) :: :ok | {:error, :checksum_mismatch}
  defp verify_checksum(%Manifest{checksum: declared}, dir, %{require_checksum: true}) do
    case declared do
      value when is_binary(value) ->
        if secure_equal?(normalize(value), checksum(dir)),
          do: :ok,
          else: {:error, :checksum_mismatch}

      _ ->
        {:error, :checksum_mismatch}
    end
  end

  defp verify_checksum(_manifest, _dir, _policy), do: :ok

  @spec verify_signature(Manifest.t(), map()) :: :ok | {:error, :unsigned}
  defp verify_signature(_manifest, %{require_signature: true}), do: {:error, :unsigned}
  defp verify_signature(_manifest, _policy), do: :ok

  @doc "Content digest (sha256, lowercase hex) over every package file except `plugin.json`."
  @spec checksum(String.t()) :: String.t()
  def checksum(dir) do
    dir
    |> package_files()
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      rel = Path.relative_to(file, dir)

      acc
      |> :crypto.hash_update(rel)
      |> :crypto.hash_update(File.read!(file))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @spec package_files(String.t()) :: [String.t()]
  defp package_files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == Manifest.filename()))
  end

  # Strip an optional `sha256:` prefix and lowercase.
  @spec normalize(String.t()) :: String.t()
  defp normalize(value) do
    value
    |> String.replace_prefix("sha256:", "")
    |> String.downcase()
  end

  @spec secure_equal?(String.t(), String.t()) :: boolean()
  defp secure_equal?(a, b), do: Plug.Crypto.secure_compare(a, b)
end
