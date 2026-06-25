defmodule RepoBuilder.Forge.Packager do
  @moduledoc """
  Turn a validated forge artifact into a real plugin (forge-meta-artifact-generation,
  Phase 4): synthesize an `agentic.plugin/1` `plugin.json` (kebab `id`, semver `version`,
  the one right `contributions[]` entry, a sha256 checksum) and write the package into
  `plugin_library/<id>/` so the existing `Plugins.Installer` (`"library"` source) can
  install it unchanged.

  The package is round-trip-verified: the manifest the Packager writes is read back through
  the strict `Plugins.Manifest.parse/1` boundary before the package is declared good — the
  wire→domain contract holds in both directions. The checksum uses the SAME digest the
  install trust gate computes (`Plugins.Trust.checksum/1`, over every file except
  `plugin.json`), so a checksum-enforcing policy accepts a forged package.
  """
  alias RepoBuilder.Forge.Artifact
  alias RepoBuilder.Forge.Generator.Def
  alias RepoBuilder.Plugins.{Manifest, Registry, Trust}

  @version "0.1.0"

  @typedoc "A successful package: the plugin id/version and the package dir on disk."
  @type packaged :: %{id: String.t(), version: String.t(), dir: String.t()}

  @type reason ::
          :no_asset_subdir
          | :empty_asset
          | {:copy_failed, term()}
          | {:manifest_write, File.posix()}
          | {:manifest_roundtrip, Manifest.reason()}
          | {:undeterminable_id, term()}

  @doc """
  Package the validated artifact staged under `scratch` into `plugin_library/<id>/`.
  `def_t` supplies the target contribution kind + asset subdir. Returns the package
  descriptor or a tagged error (never raises on the expected paths).
  """
  @spec package(Artifact.t(), Def.t(), String.t()) :: {:ok, packaged()} | {:error, reason()}
  def package(%Artifact{} = _artifact, %Def{} = def_t, scratch) when is_binary(scratch) do
    asset_src = Path.join(scratch, def_t.asset_subdir)

    with {:ok, id} <- derive_id(def_t, asset_src),
         dir = package_dir(id),
         :ok <- stage(asset_src, dir, def_t.asset_subdir),
         :ok <- write_manifest(dir, id, def_t),
         :ok <- verify_roundtrip(dir) do
      {:ok, %{id: id, version: @version, dir: dir}}
    end
  end

  # --- id derivation (the artifact's natural name) ---

  @spec derive_id(Def.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp derive_id(%Def{kind: :skill}, asset_src) do
    # skills/<name>/SKILL.md → the bundle dir name.
    case first_subdir(asset_src) do
      nil -> {:error, :empty_asset}
      name -> {:ok, name}
    end
  end

  defp derive_id(%Def{kind: :workflow}, asset_src) do
    # workflows/<slug>.json → the slug inside the JSON (fall back to the filename).
    case first_file(asset_src, ".json") do
      nil ->
        {:error, :empty_asset}

      file ->
        slug =
          with {:ok, json} <- File.read(file),
               {:ok, %{"slug" => slug}} when is_binary(slug) <- Jason.decode(json) do
            slug
          else
            _ -> Path.rootname(Path.basename(file))
          end

        {:ok, slug}
    end
  end

  defp derive_id(%Def{}, asset_src) do
    # commands/<name>.md, agents/<name>.md → the file basename.
    case first_file(asset_src, ".md") do
      nil -> {:error, :empty_asset}
      file -> {:ok, Path.rootname(Path.basename(file))}
    end
  end

  # --- staging the package on disk ---

  # No @spec: the error union is narrower than `reason()` — an inference-only spec avoids a
  # dialyzer `contract_supertype` (private fn, credo-exempt).
  defp stage(asset_src, dir, asset_subdir) do
    if File.dir?(asset_src) do
      target = Path.join(dir, asset_subdir)
      _ = File.rm_rf(dir)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           {:ok, _} <- File.cp_r(asset_src, target) do
        :ok
      else
        {:error, reason} -> {:error, {:copy_failed, reason}}
      end
    else
      {:error, :no_asset_subdir}
    end
  end

  # --- the synthesized manifest ---

  @spec write_manifest(String.t(), String.t(), Def.t()) ::
          :ok | {:error, {:manifest_write, File.posix()}}
  defp write_manifest(dir, id, %Def{contribution_kind: kind, asset_subdir: subdir}) do
    manifest = %{
      "schema" => Manifest.schema(),
      "id" => id,
      "name" => titleize(id),
      "version" => @version,
      "description" => "Forged #{kind} plugin (#{id}).",
      "author" => "repo_builder.forge",
      "compat" => %{"platform" => ">= 0.0.0"},
      "contributions" => [%{"kind" => Atom.to_string(kind), "path" => subdir}],
      # Digest over every package file EXCEPT plugin.json — matches the trust gate.
      "checksum" => Trust.checksum(dir)
    }

    case File.write(Path.join(dir, Manifest.filename()), Jason.encode!(manifest, pretty: true)) do
      :ok -> :ok
      {:error, posix} -> {:error, {:manifest_write, posix}}
    end
  end

  @spec verify_roundtrip(String.t()) :: :ok | {:error, {:manifest_roundtrip, Manifest.reason()}}
  defp verify_roundtrip(dir) do
    case Manifest.read(dir) do
      {:ok, %Manifest{}} -> :ok
      {:error, reason} -> {:error, {:manifest_roundtrip, reason}}
    end
  end

  # --- helpers ---

  @spec package_dir(String.t()) :: String.t()
  defp package_dir(id), do: Path.join(Registry.library_dir(), id)

  @spec first_subdir(String.t()) :: String.t() | nil
  defp first_subdir(dir) do
    with {:ok, entries} <- File.ls(dir),
         name when is_binary(name) <- Enum.find(entries, &File.dir?(Path.join(dir, &1))) do
      name
    else
      _ -> nil
    end
  end

  @spec first_file(String.t(), String.t()) :: String.t() | nil
  defp first_file(dir, ext) do
    with {:ok, entries} <- File.ls(dir),
         name when is_binary(name) <- Enum.find(entries, &String.ends_with?(&1, ext)) do
      Path.join(dir, name)
    else
      _ -> nil
    end
  end

  @spec titleize(String.t()) :: String.t()
  defp titleize(id) do
    id
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
