defmodule RepoBuilder.Plugins.Loader do
  @moduledoc """
  Boot reconciler + code loader for installed plugins (the agentic plugin system
  foundation). On boot (gated off in tests) it scans `agentic_plugins/`, reconciles
  what's on disk against the `plugins` table, and loads any CODE-bearing plugins:
  `Code.require_file/1` each declared module, then call the `on_load/1` of the
  manifest's `code.on_load` module (a `RepoBuilder.Plugins.Code` impl).

  Code loading is serialized through this GenServer and is reload-required (never
  mid-request). `reload/0` re-scans on demand. Declarative contributions need no
  loading — they are read live by `Plugins.Activation`.
  """
  use GenServer
  require Logger

  alias RepoBuilder.Plugins.{Manifest, Registry}

  @type result :: %{loaded: [String.t()], skipped: [String.t()], errors: [{String.t(), term()}]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Re-scan `agentic_plugins/` and (re)load code plugins. Returns a load summary."
  @spec reload() :: result()
  def reload, do: GenServer.call(__MODULE__, :reload, 30_000)

  @doc "Load the code layer of a single staged/installed package dir."
  @spec load_code(Manifest.t(), String.t()) :: :ok | {:error, term()}
  def load_code(%Manifest{} = manifest, dir), do: do_load_code(manifest, dir)

  @impl true
  def init(opts) do
    reconcile? = Keyword.get(opts, :reconcile_on_boot?, reconcile_on_boot?())
    if reconcile?, do: send(self(), :reload)
    {:ok, %{loaded: MapSet.new()}}
  end

  @impl true
  def handle_info(:reload, state) do
    {_result, state} = do_reload(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {result, state} = do_reload(state)
    {:reply, result, state}
  end

  @spec do_reload(map()) :: {result(), map()}
  defp do_reload(state) do
    {result, loaded} =
      Registry.install_dir()
      |> scan()
      |> Enum.reduce({%{loaded: [], skipped: [], errors: []}, state.loaded}, &reduce_entry/2)

    {result, %{state | loaded: loaded}}
  end

  @spec reduce_entry({String.t(), Manifest.t()}, {result(), MapSet.t()}) :: {result(), MapSet.t()}
  defp reduce_entry({dir, manifest}, {acc, loaded}) do
    tag = "#{manifest.id}@#{manifest.version}"

    cond do
      not Manifest.code?(manifest) -> {skip(acc, tag), loaded}
      MapSet.member?(loaded, tag) -> {skip(acc, tag), loaded}
      true -> load_and_track(manifest, dir, tag, acc, loaded)
    end
  end

  @spec skip(result(), String.t()) :: result()
  defp skip(acc, tag), do: Map.update!(acc, :skipped, &[tag | &1])

  @spec load_and_track(Manifest.t(), String.t(), String.t(), result(), MapSet.t()) ::
          {result(), MapSet.t()}
  defp load_and_track(manifest, dir, tag, acc, loaded) do
    case do_load_code(manifest, dir) do
      :ok ->
        {Map.update!(acc, :loaded, &[tag | &1]), MapSet.put(loaded, tag)}

      {:error, reason} ->
        Logger.warning("plugin code load failed for #{tag}: #{inspect(reason)}")
        {Map.update!(acc, :errors, &[{tag, reason} | &1]), loaded}
    end
  end

  # Every `<id>@<version>/plugin.json` under the install dir, parsed.
  @spec scan(String.t()) :: [{String.t(), Manifest.t()}]
  defp scan(install_dir) do
    case File.ls(install_dir) do
      {:ok, entries} ->
        for entry <- entries,
            dir = Path.join(install_dir, entry),
            File.dir?(dir),
            {:ok, manifest} <- [Manifest.read(dir)] do
          {dir, manifest}
        end

      _ ->
        []
    end
  end

  @spec do_load_code(Manifest.t(), String.t()) :: :ok | {:error, term()}
  defp do_load_code(%Manifest{code: code} = manifest, dir) when is_map(code) do
    with :ok <- require_modules(Map.get(code, "modules", []), dir),
         {:ok, module} <- on_load_module(code) do
      call_on_load(module, manifest, dir)
    end
  end

  defp do_load_code(_manifest, _dir), do: :ok

  @spec require_modules(term(), String.t()) :: :ok | {:error, term()}
  defp require_modules(modules, dir) when is_list(modules) do
    Enum.reduce_while(modules, :ok, fn rel, :ok ->
      path = Path.join(dir, to_string(rel))

      try do
        _ = Elixir.Code.require_file(path)
        {:cont, :ok}
      rescue
        error -> {:halt, {:error, {:require_failed, rel, error}}}
      end
    end)
  end

  defp require_modules(_modules, _dir), do: :ok

  @spec on_load_module(map()) :: {:ok, module()} | {:error, :no_on_load}
  defp on_load_module(%{"on_load" => name}) when is_binary(name) do
    {:ok, Module.concat([name])}
  end

  defp on_load_module(_code), do: {:error, :no_on_load}

  @spec call_on_load(module(), Manifest.t(), String.t()) :: :ok | {:error, term()}
  defp call_on_load(module, manifest, dir) do
    ctx = %{plugin_id: manifest.id, version: manifest.version, install_path: dir}

    if Elixir.Code.ensure_loaded?(module) and function_exported?(module, :on_load, 1) do
      module.on_load(ctx)
    else
      {:error, {:not_a_code_plugin, module}}
    end
  rescue
    error -> {:error, {:on_load_raised, error}}
  end

  @spec reconcile_on_boot?() :: boolean()
  defp reconcile_on_boot? do
    Application.get_env(:repo_builder, :plugins, [])
    |> Keyword.get(:reconcile_on_boot?, true)
  end
end
