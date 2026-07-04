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
  alias RepoBuilder.Definitions.Adw, as: AdwDef

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

  @doc """
  A merged, de-duplicated, grouped list of loadable ADW entries from both the platform
  root and the operator's `working_dir`, suitable for the LOAD COMBO grouped picker.

  Returns `[%{kind, name, source, ref, steps, flavor}]` where:
  - `kind: :combo` — a saved combo with a JSON sidecar (loadable via `fetch/2`).
  - `kind: :adw` — a discovered `adws/adw_*.py` without a sidecar.
  - `source: :platform | :project` — where the entry comes from.
  - `ref` — the stem name for combos, the full path for discovered ADWs.
  - `steps` — the reconstructed step-atom list (from the filename stem for ADWs; the
    actual steps for combos). May be `[]` for ADWs with unmappable stems.
  - `flavor` — the reconstructed flavor atom (from the filename suffix for ADWs).
  """
  @type loadable_entry :: %{
          kind: :combo | :adw,
          name: String.t(),
          source: :platform | :project,
          ref: String.t(),
          steps: [atom()],
          flavor: Combo.flavor()
        }

  @spec loadable(String.t() | nil) :: [loadable_entry()]
  def loadable(working_dir) do
    platform_root = definitions_root()
    project_root = working_dir && working_dir != "" && working_dir

    combo_entries = load_combo_entries(platform_root, project_root)
    adw_entries = load_adw_entries(platform_root, project_root, combo_entries)

    (combo_entries ++ adw_entries)
    |> Enum.uniq_by(& &1.ref)
  end

  @doc """
  Parse the step atoms from an ADW script filename stem (without the `adw_` prefix).
  E.g. `"plan_build_review_iso"` → `[:plan, :build, :review]`.
  Returns `[]` for stems whose parts don't all map to the step allowlist.
  """
  @spec steps_from_stem(String.t()) :: [atom()]
  def steps_from_stem(stem) when is_binary(stem) do
    valid = Scaffold.valid_steps() |> MapSet.new()

    step_atoms = %{
      "plan" => :plan,
      "patch" => :patch,
      "build" => :build,
      "test" => :test,
      "review" => :review,
      "document" => :document,
      "ship" => :ship
    }

    # Strip known suffixes first, then split the remaining stem by "_".
    base =
      cond do
        String.ends_with?(stem, "_local_iso") ->
          String.slice(stem, 0, byte_size(stem) - byte_size("_local_iso"))

        String.ends_with?(stem, "_direct") ->
          String.slice(stem, 0, byte_size(stem) - byte_size("_direct"))

        String.ends_with?(stem, "_iso") ->
          String.slice(stem, 0, byte_size(stem) - byte_size("_iso"))

        true ->
          stem
      end

    parts = String.split(base, "_") |> Enum.reject(&(&1 == ""))

    atoms = Enum.map(parts, &Map.get(step_atoms, &1))

    if Enum.all?(atoms, &(&1 != nil and &1 in valid)),
      do: atoms,
      else: []
  end

  def steps_from_stem(_other), do: []

  @doc "Parse the flavor atom from an ADW script filename stem. Defaults to `:iso`."
  @spec flavor_from_stem(String.t()) :: Combo.flavor()
  def flavor_from_stem(stem) when is_binary(stem) do
    cond do
      String.ends_with?(stem, "_local_iso") -> :local_iso
      String.ends_with?(stem, "_direct") -> :direct
      true -> :iso
    end
  end

  def flavor_from_stem(_other), do: :iso

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
      :direct -> :direct
      "direct" -> :direct
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

  @spec load_combo_entries(String.t(), String.t() | false | nil) :: [loadable_entry()]
  defp load_combo_entries(platform_root, project_root) do
    platform_combos =
      list(platform_root)
      |> Enum.map(fn combo ->
        %{
          kind: :combo,
          name: combo.name,
          source: :platform,
          ref: combo.name,
          steps: Enum.map(combo.steps, & &1.name),
          flavor: combo.flavor
        }
      end)

    if project_root && project_root != platform_root do
      project_combos =
        list(project_root)
        |> Enum.map(fn combo ->
          %{
            kind: :combo,
            name: combo.name,
            source: :project,
            ref: combo.name,
            steps: Enum.map(combo.steps, & &1.name),
            flavor: combo.flavor
          }
        end)

      seen = MapSet.new(platform_combos, & &1.name)
      fresh_project = Enum.reject(project_combos, &MapSet.member?(seen, &1.name))
      platform_combos ++ fresh_project
    else
      platform_combos
    end
  end

  @spec load_adw_entries(String.t(), String.t() | false | nil, [loadable_entry()]) ::
          [loadable_entry()]
  defp load_adw_entries(platform_root, project_root, combo_entries) do
    combo_refs = MapSet.new(combo_entries, & &1.ref)
    working_dir = if project_root && project_root != platform_root, do: project_root, else: nil

    platform_adws =
      AdwDef.scan(platform_root, :app)
      |> Enum.map(fn adw ->
        %{
          kind: :adw,
          name: adw.name,
          source: :platform,
          ref: adw.path,
          steps: steps_from_stem(adw.name),
          flavor: flavor_from_stem(adw.name)
        }
      end)

    project_adws =
      if working_dir do
        AdwDef.scan(working_dir, :working_dir)
        |> Enum.map(fn adw ->
          %{
            kind: :adw,
            name: adw.name,
            source: :project,
            ref: adw.path,
            steps: steps_from_stem(adw.name),
            flavor: flavor_from_stem(adw.name)
          }
        end)
      else
        []
      end

    seen_adw_names = MapSet.new()

    (platform_adws ++ project_adws)
    |> Enum.reject(fn adw ->
      MapSet.member?(combo_refs, adw.ref) or
        String.contains?(adw.ref, @combos_subdir)
    end)
    |> Enum.uniq_by(& &1.name)
    |> tap(fn _ -> seen_adw_names end)
  end
end
