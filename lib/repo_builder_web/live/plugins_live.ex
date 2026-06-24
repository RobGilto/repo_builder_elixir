defmodule RepoBuilderWeb.PluginsLive do
  @moduledoc """
  The plugin store / management UI (the agentic plugin system foundation) at
  `/plugins`. Browse each source's catalog (the local library + the remote store),
  install / uninstall packages, and activate / deactivate them for the platform scope
  (`nil` project). Code-bearing manifests surface an explicit trust warning before
  install. All state goes through the `Plugins` / `Installer` contexts — never `Repo`.
  """
  use RepoBuilderWeb, :live_view

  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Installer, Manifest, Registry}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Plugins.subscribe()
    {:ok, assign(socket, page_title: "Plugins") |> load()}
  end

  @impl true
  def handle_event("install", %{"source" => source, "id" => id, "version" => version}, socket) do
    case Installer.install(source, id, version) do
      {:ok, plugin} ->
        {:noreply,
         socket |> put_flash(:info, "Installed #{plugin.plugin_id}@#{plugin.version}") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Install failed: #{inspect(reason)}")}
    end
  end

  def handle_event("uninstall", %{"id" => id}, socket) do
    :ok = Installer.uninstall(id)
    {:noreply, socket |> put_flash(:info, "Uninstalled #{id}") |> load()}
  end

  def handle_event("activate", %{"id" => id}, socket) do
    case Plugins.activate(nil, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Activated #{id}") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not activate #{id}")}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    :ok = Plugins.deactivate(nil, id)
    {:noreply, socket |> put_flash(:info, "Deactivated #{id}") |> load()}
  end

  @impl true
  def handle_info({:plugins_changed, _project_id}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    installed = Plugins.list_installed()
    active_ids = nil |> Plugins.list_active() |> MapSet.new(& &1.plugin_id)

    assign(socket,
      installed: installed,
      active_ids: active_ids,
      catalog: catalog()
    )
  end

  # The merged catalog from every configured source (best-effort; a source that errors
  # contributes nothing rather than crashing the page).
  defp catalog do
    for key <- Enum.sort(Registry.source_keys()),
        {:ok, module} <- [Registry.source_module(key)],
        {:ok, config} <- [Registry.source_config(key)],
        {:ok, summaries} <- [safe_list(module, config)],
        summary <- summaries do
      Map.put(summary, :source, key)
    end
  end

  defp safe_list(module, config) do
    module.list(config)
  rescue
    _ -> {:ok, []}
  end

  defp installed?(installed, id), do: Enum.any?(installed, &(&1.plugin_id == id))

  # Whether a catalog entry ships a code layer (surfaces the in-node trust warning).
  # Cheap for the local library (read its manifest); other sources default to false
  # and are re-checked at install time by the trust gate.
  defp code?(%{source: "library", id: id}) do
    case Manifest.read(Path.join(Registry.library_dir(), id)) do
      {:ok, parsed} -> Manifest.code?(parsed)
      _ -> false
    end
  end

  defp code?(_entry), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <.link navigate={~p"/"} class="text-cyan-400 text-sm">← back to console</.link>
        <h1 class="text-xl font-semibold">Plugins</h1>
        <p class="text-sm text-zinc-400">
          Install plugins into <code class="text-cyan-300">agentic_plugins/</code>, then activate
          them for the platform. Switching the orchestrator's project changes which plugins apply.
        </p>

        <section>
          <h2 class="font-semibold mb-2">Installed</h2>
          <ul id="installed-plugins" class="space-y-2">
            <li
              :for={plugin <- @installed}
              id={"installed-#{plugin.plugin_id}"}
              class="rounded border border-zinc-700 p-3 flex items-center justify-between"
            >
              <div>
                <span class="font-medium text-zinc-100">{plugin.plugin_id}</span>
                <span class="ml-1 text-xs text-zinc-400">@{plugin.version}</span>
                <span
                  :if={MapSet.member?(@active_ids, plugin.plugin_id)}
                  class="ml-2 rounded bg-emerald-800 px-2 py-0.5 text-xs"
                >
                  active
                </span>
              </div>
              <div class="flex gap-2">
                <button
                  :if={!MapSet.member?(@active_ids, plugin.plugin_id)}
                  phx-click="activate"
                  phx-value-id={plugin.plugin_id}
                  class="rounded bg-emerald-700 px-2 py-1 text-xs"
                >
                  Activate
                </button>
                <button
                  :if={MapSet.member?(@active_ids, plugin.plugin_id)}
                  phx-click="deactivate"
                  phx-value-id={plugin.plugin_id}
                  class="rounded bg-zinc-700 px-2 py-1 text-xs"
                >
                  Deactivate
                </button>
                <button
                  phx-click="uninstall"
                  phx-value-id={plugin.plugin_id}
                  data-confirm={"Uninstall #{plugin.plugin_id}?"}
                  class="rounded bg-red-800 px-2 py-1 text-xs"
                >
                  Uninstall
                </button>
              </div>
            </li>
            <li :if={@installed == []} class="text-sm text-zinc-400">No plugins installed yet.</li>
          </ul>
        </section>

        <section>
          <h2 class="font-semibold mb-2">Available (store)</h2>
          <ul id="catalog" class="space-y-2">
            <li
              :for={entry <- @catalog}
              id={"catalog-#{entry.source}-#{entry.id}"}
              class="rounded border border-zinc-700 p-3 flex items-center justify-between"
            >
              <div>
                <span class="font-medium text-zinc-100">{entry.name}</span>
                <span class="ml-1 text-xs text-zinc-400">{entry.id}@{entry.version}</span>
                <span class="ml-2 text-xs text-zinc-500">[{entry.source}]</span>
                <span :if={code?(entry)} class="ml-2 rounded bg-amber-800 px-2 py-0.5 text-xs">
                  code plugin — runs in-node
                </span>
                <p :if={entry.description} class="text-xs text-zinc-400">{entry.description}</p>
              </div>
              <button
                :if={!installed?(@installed, entry.id)}
                phx-click="install"
                phx-value-source={entry.source}
                phx-value-id={entry.id}
                phx-value-version={entry.version}
                data-confirm={code?(entry) && "This plugin ships code that runs in-node. Install?"}
                class="rounded bg-cyan-700 px-2 py-1 text-xs"
              >
                Install
              </button>
              <span :if={installed?(@installed, entry.id)} class="text-xs text-zinc-500">installed</span>
            </li>
            <li :if={@catalog == []} class="text-sm text-zinc-400">
              No plugins available from any source.
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
