defmodule RepoBuilder.Adw.Combos do
  @moduledoc """
  The saved-combo CONTEXT — the ONLY module that touches the combos filesystem
  (mirroring the `Orchestrator.Templates` "context owns all I/O" doctrine, BUILD_PROMPT.md
  §8). Every public function is `@spec`'d, returns tagged tuples, and never raises on the
  expected paths; filesystem errors map to `{:error, reason}`.

  ## Layout & roots
  A combo persists as a JSON sidecar at `<root>/adws/.combos/<stem>.json` (the `.combos/`
  subdir is NOT matched by the `adws/adw_*.py` glob, so it never masquerades as an ADW), and
  `save/1` additionally MATERIALIZES the portable Python script via `Scaffold.generate/1` and
  calls `Definitions.refresh/1` so the ADWs palette picks up the new script.

  The writable/target `root` comes from
  `Application.get_env(:repo_builder, RepoBuilder.Adw.Combos)[:root]` (a test seam), else the
  `Definitions` app root (the platform repo). Sidecar defaults are DISTINCT from run inputs:
  they only prefill the builder.
  """
  require Logger

  alias RepoBuilder.Adw.{Combo, Scaffold}
  alias RepoBuilder.Definitions

  @type reason :: atom() | {atom(), term()}

  @combos_subdir ".combos"

  @doc "All combos under the default root, sorted by name."
  @spec list() :: [Combo.t()]
  def list, do: list(nil)

  @doc "All combos under `root` (nil ⇒ default), sorted by name."
  @spec list(String.t() | nil) :: [Combo.t()]
  def list(root) do
    dir = combos_dir(root)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&read_sidecar(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      {:error, _posix} ->
        []
    end
  end

  @doc "Fetch a single combo by display name (or stem) from the default root."
  @spec fetch(String.t()) :: {:ok, Combo.t()} | {:error, reason()}
  def fetch(name), do: fetch(name, nil)

  @doc "Fetch a single combo by display name (or stem) from `root`."
  @spec fetch(String.t(), String.t() | nil) :: {:ok, Combo.t()} | {:error, reason()}
  def fetch(name, root) when is_binary(name) do
    with {:ok, stem} <- Combo.slugify_name(name) do
      path = sidecar_path(root, stem)

      case read_sidecar(path) do
        %Combo{} = combo -> {:ok, combo}
        nil -> {:error, :not_found}
      end
    end
  end

  def fetch(_name, _root), do: {:error, :invalid_name}

  @doc """
  Validate + persist a combo: write the JSON sidecar, materialize the Python script via
  `Scaffold.generate/1`, then `Definitions.refresh/1`. `attrs` accepts atom OR string keys
  (`name`, `steps`, `flavor`, `spec`, `initial_prompt`, optional `overwrite`). On a name
  collision with an existing generated script, returns `{:error, :exists}` (surface as an
  actionable flash) unless `overwrite: true`.
  """
  @spec save(map()) :: {:ok, Combo.t()} | {:error, reason()}
  def save(attrs), do: save(attrs, nil)

  @doc "Like `save/1`, but against an explicit `root` (test seam)."
  @spec save(map(), String.t() | nil) :: {:ok, Combo.t()} | {:error, reason()}
  def save(attrs, root) when is_map(attrs) do
    with :ok <- Combo.validate(attrs),
         {:ok, stem} <- Combo.slugify_name(get(attrs, :name)),
         {:ok, steps} <- Combo.parse_steps(get(attrs, :steps)),
         flavor = flavor_of(attrs),
         {:ok, gen} <-
           Scaffold.generate(%{
             name: stem,
             steps: steps,
             flavor: flavor,
             root: resolve_root(root),
             overwrite: get(attrs, :overwrite) == true
           }) do
      combo = %Combo{
        name: stem,
        steps: steps,
        flavor: flavor,
        spec: blank(get(attrs, :spec)),
        initial_prompt: blank(get(attrs, :initial_prompt)),
        harness: blank(get(attrs, :harness)),
        script_path: gen.path,
        updated_at: DateTime.utc_now()
      }

      case write_sidecar(root, stem, combo) do
        :ok ->
          refresh_definitions()
          {:ok, combo}

        {:error, _reason} = err ->
          err
      end
    end
  end

  def save(_attrs, _root), do: {:error, :invalid_attrs}

  @doc """
  Delete a combo's sidecar (leaving the generated `.py`, which is now a normal discovered
  ADW). Unknown name ⇒ `{:error, :not_found}`.
  """
  @spec delete(binary()) :: :ok | {:error, atom()}
  def delete(name), do: delete(name, nil)

  @doc "Like `delete/1`, but against an explicit `root`."
  @spec delete(String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def delete(name, root) when is_binary(name) do
    with {:ok, stem} <- Combo.slugify_name(name) do
      path = sidecar_path(root, stem)

      if File.exists?(path), do: rm(path), else: {:error, :not_found}
    end
  end

  def delete(_name, _root), do: {:error, :invalid_name}

  # --- internals ---

  @spec rm(binary()) :: :ok | {:error, atom()}
  defp rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, posix} -> {:error, posix}
    end
  end

  @spec read_sidecar(String.t()) :: Combo.t() | nil
  defp read_sidecar(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw),
         {:ok, combo} <- Combo.from_json(map) do
      combo
    else
      error ->
        Logger.warning("skipping unreadable combo sidecar #{path}: #{inspect(error)}")
        nil
    end
  end

  @spec write_sidecar(String.t() | nil, String.t(), Combo.t()) :: :ok | {:error, reason()}
  defp write_sidecar(root, stem, combo) do
    path = sidecar_path(root, stem)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(Combo.to_json(combo), pretty: true) do
      File.write(path, json)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:write_failed, Exception.message(error)}}
  end

  @spec refresh_definitions() :: :ok
  defp refresh_definitions do
    # Best-effort: the palette refresh must never fail a save. In tests the watcher may
    # be pointed elsewhere or absent; a running console re-scans its own working_dir.
    if is_pid(Process.whereis(Definitions)), do: Definitions.refresh(nil)
    :ok
  rescue
    _error -> :ok
  end

  @spec sidecar_path(String.t() | nil, String.t()) :: String.t()
  defp sidecar_path(root, stem), do: Path.join(combos_dir(root), "#{stem}.json")

  @spec combos_dir(String.t() | nil) :: String.t()
  defp combos_dir(root), do: Path.join([resolve_root(root), "adws", @combos_subdir])

  @spec resolve_root(String.t() | nil) :: String.t()
  defp resolve_root(root) when is_binary(root), do: root

  defp resolve_root(nil) do
    case Application.get_env(:repo_builder, __MODULE__, [])[:root] do
      dir when is_binary(dir) -> dir
      _nil -> definitions_root()
    end
  end

  @spec definitions_root() :: String.t()
  defp definitions_root do
    case Application.get_env(:repo_builder, Definitions, [])[:app_root] do
      dir when is_binary(dir) -> dir
      _nil -> File.cwd!()
    end
  end

  @spec flavor_of(map()) :: Combo.flavor()
  defp flavor_of(attrs) do
    case get(attrs, :flavor) do
      :local_iso -> :local_iso
      "local_iso" -> :local_iso
      _other -> if get(attrs, :local) == true, do: :local_iso, else: :iso
    end
  end

  @spec get(
          map(),
          :flavor | :harness | :initial_prompt | :local | :name | :overwrite | :spec | :steps
        ) :: any()
  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(_other), do: nil
end
