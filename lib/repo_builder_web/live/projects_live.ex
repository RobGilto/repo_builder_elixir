defmodule RepoBuilderWeb.ProjectsLive do
  @moduledoc """
  Target-repo management (agentic-layer adaptor, Phase 5): list + register projects at
  `/projects`, and a per-project dashboard at `/projects/:id` (repo health, capability
  map, resolved command set with provenance, discovered ADWs, recent runs, cost rollup,
  and a command-pack picker). Registration runs the Profiler so the operator sees the
  detected stack before/after save.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.ProjectComponents

  alias RepoBuilder.Commands
  alias RepoBuilder.FileBrowser
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Projects.WorktreeInventory
  alias RepoBuilder.Projects.WorktreeInventory.Entry
  alias RepoBuilder.Secrets
  alias RepoBuilder.Settings
  alias RepoBuilder.StackLayers
  alias RepoBuilder.StackLayers.Contract
  alias RepoBuilder.StackLayers.StackLayer
  alias RepoBuilder.Workflows

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, register_form: %{"name" => "", "root_path" => ""}, error: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Projects",
      projects: Projects.list_projects(),
      project: nil,
      platform_id: platform_id()
    )
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    with {:ok, project} <- Projects.fetch_project(id),
         {:ok, orchestrator} <- Orchestrators.get_or_create_for_project(project.id) do
      socket
      |> assign(page_title: project.name, project: project)
      |> assign(resolved: Commands.resolve_all(project))
      |> assign(runs: Workflows.list_recent_for_project(project.id, 20))
      |> assign(cost: project_cost(project.id))
      |> assign(secrets: Secrets.list_names(project.id))
      |> assign(secret_form: %{"name" => "", "value" => ""})
      |> assign(orchestrator: orchestrator, model_rows: model_rows(orchestrator))
      |> assign(design_system: resolve_design(project))
      |> assign_stack_layers(project.id)
      # Worktree inventory shells out to git per entry — load it async so the show
      # page's first paint never blocks on it (console-mount-perf discipline).
      |> assign(worktrees: nil)
      |> reload_worktrees()
    else
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> push_navigate(to: ~p"/projects")

      {:error, _changeset} ->
        socket
        |> put_flash(:error, "Could not resolve an orchestrator for this project")
        |> push_navigate(to: ~p"/projects")
    end
  end

  @impl true
  def handle_event("validate_register", params, socket) do
    {:noreply, assign(socket, register_form: register_fields(params))}
  end

  def handle_event("register", params, socket) do
    case Projects.create_and_profile(register_fields(params)) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Registered #{project.name} (#{stack_of(project)})")
         |> push_navigate(to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, error: error_message(changeset), register_form: register_fields(params))}
    end
  end

  def handle_event("refresh_profile", _params, socket) do
    {:ok, project} = Projects.refresh_profile(socket.assigns.project)

    {:noreply,
     socket
     |> assign(project: project, resolved: Commands.resolve_all(project))
     |> put_flash(:info, "Re-profiled #{project.name}")}
  end

  def handle_event(
        "set_pack",
        %{"command_pack" => pack, "command_pack_version" => version},
        socket
      ) do
    case Projects.update_project(socket.assigns.project, %{
           "command_pack" => pack,
           "command_pack_version" => version
         }) do
      {:ok, project} ->
        {:noreply, assign(socket, project: project, resolved: Commands.resolve_all(project))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update command pack")}
    end
  end

  # Override one worker tier for THIS project (per-project roster card). Same cascade as
  # the console modal: changing harness clears provider+model; changing provider clears
  # model. Writes through the per-project seam (`set_agent_model/3`), so other projects
  # are untouched.
  def handle_event("set_project_model", %{"category" => category} = params, socket) do
    orchestrator = socket.assigns.orchestrator
    stored = Enum.find(socket.assigns.model_rows, %{}, &(&1.category == category))
    attrs = project_model_attrs(params, stored)

    case Orchestrators.set_agent_model(orchestrator.id, category, attrs) do
      {:ok, updated} ->
        {:noreply, assign(socket, orchestrator: updated, model_rows: model_rows(updated))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update model")}
    end
  end

  # Reset a tier to the global default (clears the per-project override so it re-inherits).
  def handle_event("clear_project_model", %{"category" => category}, socket) do
    orchestrator = socket.assigns.orchestrator

    case Orchestrators.clear_agent_model(orchestrator.id, category) do
      {:ok, updated} ->
        {:noreply, assign(socket, orchestrator: updated, model_rows: model_rows(updated))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not reset model")}
    end
  end

  # Mix & match one layer per type (stack-layers subsystem). Replaces whichever layer of
  # this type is currently selected: deselect the type's current pick, then select the new
  # one (or leave the type empty when "none"). Re-renders the live contract preview.
  def handle_event(
        "select_stack_layer",
        %{"layer_type" => layer_type, "stack_layer_id" => stack_layer_id},
        socket
      ) do
    project_id = socket.assigns.project.id

    Enum.each(
      layers_of_type(project_id, layer_type),
      &StackLayers.deselect_layer(project_id, &1.id)
    )

    _ =
      if stack_layer_id not in [nil, ""] do
        StackLayers.select_layer(project_id, stack_layer_id)
      end

    {:noreply, assign_stack_layers(socket, project_id)}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    if id == platform_id() do
      {:noreply, put_flash(socket, :error, "The platform repo project can't be deregistered")}
    else
      deregister_project(socket, id)
    end
  end

  def handle_event("add_secret", %{"name" => name, "value" => value}, socket) do
    project = socket.assigns.project

    case Secrets.put_secret(project.id, name, value) do
      {:ok, _secret} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved secret #{name}")
         # Never re-render the value: reset the form to a blank name/value pair.
         |> assign(
           secrets: Secrets.list_names(project.id),
           secret_form: %{"name" => "", "value" => ""}
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(secret_form: %{"name" => name, "value" => ""})}
    end
  end

  def handle_event("delete_secret", %{"name" => name}, socket) do
    project = socket.assigns.project
    :ok = Secrets.delete_secret(project.id, name)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted secret #{name}")
     |> assign(secrets: Secrets.list_names(project.id))}
  end

  # --- worktree management panel (worktree-panel-and-gc plan) ---

  def handle_event("refresh_worktrees", _params, socket) do
    {:noreply, reload_worktrees(socket)}
  end

  def handle_event("merge_worktree", %{"branch" => branch}, socket) do
    socket =
      case WorktreeInventory.merge(socket.assigns.project, branch) do
        {:ok, %{sha: sha, trunk: trunk}} ->
          put_flash(
            socket,
            :info,
            "#{branch} merged @ #{String.slice(sha, 0, 7)} into #{trunk}"
          )

        {:error, reason} ->
          put_flash(socket, :error, "Merge failed: #{format_reason(reason)}")
      end

    {:noreply,
     socket
     |> assign(runs: Workflows.list_recent_for_project(socket.assigns.project.id, 20))
     |> reload_worktrees()}
  end

  def handle_event("remove_worktree", %{"branch" => branch}, socket) do
    remove_worktree_and_reload(socket, branch, delete_branch: false)
  end

  def handle_event("remove_worktree_branch", %{"branch" => branch}, socket) do
    remove_worktree_and_reload(socket, branch, delete_branch: true)
  end

  def handle_event("gc_worktrees", _params, socket) do
    {:ok, count} = WorktreeInventory.gc(socket.assigns.project)

    {:noreply,
     socket
     |> put_flash(:info, "Reclaimed #{count} merged worktree(s)")
     |> reload_worktrees()}
  end

  def handle_event("prune_worktrees", _params, socket) do
    :ok = Worktree.prune(socket.assigns.project.root_path)

    {:noreply,
     socket |> put_flash(:info, "Pruned stale worktree registrations") |> reload_worktrees()}
  end

  def handle_event("toggle_isolation", _params, socket) do
    project = socket.assigns.project
    next = if project.isolation_mode == :worktree, do: :direct, else: :worktree

    case Projects.update_project(project, %{isolation_mode: next}) do
      {:ok, updated} ->
        {:noreply, assign(socket, project: updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update isolation mode")}
    end
  end

  @impl true
  def handle_async(:load_worktrees, {:ok, {:ok, entries}}, socket) do
    {:noreply, assign(socket, worktrees: entries)}
  end

  def handle_async(:load_worktrees, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(worktrees: [])
     |> put_flash(:error, "Worktree inventory failed: #{format_reason(reason)}")}
  end

  # Kick (or re-kick) the async inventory load for the currently shown project.
  @spec reload_worktrees(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reload_worktrees(socket) do
    project = socket.assigns.project
    start_async(socket, :load_worktrees, fn -> WorktreeInventory.list(project) end)
  end

  @spec remove_worktree_and_reload(Phoenix.LiveView.Socket.t(), String.t(), keyword()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp remove_worktree_and_reload(socket, branch, opts) do
    socket =
      case find_worktree(socket, branch) do
        %Entry{} = entry ->
          # The data-confirm dialog IS the explicit choice, so force past the
          # unmerged-work guard here.
          case WorktreeInventory.remove(
                 socket.assigns.project,
                 entry,
                 Keyword.put(opts, :force, true)
               ) do
            :ok ->
              put_flash(socket, :info, "Removed #{branch}")

            {:error, reason} ->
              put_flash(socket, :error, "Remove failed: #{format_reason(reason)}")
          end

        nil ->
          put_flash(socket, :error, "Unknown worktree #{branch} — refresh and retry")
      end

    {:noreply, reload_worktrees(socket)}
  end

  @spec find_worktree(Phoenix.LiveView.Socket.t(), String.t()) :: Entry.t() | nil
  defp find_worktree(socket, branch) do
    case socket.assigns.worktrees do
      entries when is_list(entries) -> Enum.find(entries, &(&1.branch == branch))
      _not_loaded -> nil
    end
  end

  @spec worktree_dom_id(Entry.t()) :: String.t()
  defp worktree_dom_id(%Entry{branch: branch}), do: "wt-" <> String.replace(branch, "/", "-")

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # The platform's own "repo" project (seeded row whose root_path is the BEAM cwd). It is the
  # safe home the console falls back to, so it must never be deregistered. `nil` before seeding.
  @spec platform_id() :: Ecto.UUID.t() | nil
  defp platform_id do
    case Projects.default_project() do
      nil -> nil
      project -> project.id
    end
  end

  # Deregister a project and, if it was the persisted console selection, drop that pointer so
  # "back to console" resolves to the platform repo project (via `Projects.active_or_default/1`)
  # instead of a now-dead id. Historical agents/runs are kept (FK is unscoped on delete).
  @spec deregister_project(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp deregister_project(socket, id) do
    with {:ok, project} <- Projects.fetch_project(id),
         {:ok, _} <- Projects.delete_project(project) do
      _ = if Settings.get_active_project_id() == id, do: Settings.put_active_project_id(nil)

      {:noreply,
       socket
       |> put_flash(:info, "Deregistered #{project.name}")
       |> push_navigate(to: ~p"/projects")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not deregister project")}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <.link navigate={~p"/"} class="text-cyan-400 text-sm">
          ← back to console
        </.link>
        <h1 class="text-xl font-semibold">Projects</h1>

        <ul id="projects" class="space-y-2">
          <li
            :for={project <- @projects}
            class="flex items-center justify-between rounded border border-zinc-700 p-3"
          >
            <div>
              <.link navigate={~p"/projects/#{project.id}"} class="font-medium text-cyan-400">
                {project.name}
              </.link>
              <span class="ml-2 text-xs text-zinc-400">{project.root_path}</span>
            </div>
            <button
              :if={project.id != @platform_id}
              phx-click="delete_project"
              phx-value-id={project.id}
              data-confirm={"Deregister #{project.name}? Historical agents/runs are kept (unscoped)."}
              class="rounded bg-red-800 px-2 py-1 text-xs"
            >
              Deregister
            </button>
          </li>
          <li :if={@projects == []} class="text-sm text-zinc-400">
            No projects yet — register a target repo below.
          </li>
        </ul>

        <form
          id="register-project"
          phx-change="validate_register"
          phx-submit="register"
          class="space-y-2 max-w-xl"
        >
          <h2 class="font-semibold">Register a target repo</h2>
          <p :if={@error} class="text-sm text-red-400">{@error}</p>
          <input
            name="name"
            value={@register_form["name"]}
            placeholder="Project name"
            class="w-full rounded border border-zinc-600 bg-zinc-800 px-2 py-1 text-sm"
          />
          <input
            name="root_path"
            value={@register_form["root_path"]}
            placeholder="/absolute/path/to/repo"
            class="w-full rounded border border-zinc-600 bg-zinc-800 px-2 py-1 text-sm font-mono"
          />
          <p class="text-xs text-zinc-500">{path_hint(@register_form["root_path"])}</p>
          <label class="flex items-center gap-2 text-xs text-zinc-400">
            <input
              type="checkbox"
              name="create_dir"
              value="true"
              checked={@register_form["create_dir"] == "true"}
            /> Create the folder if it doesn't exist yet
          </label>
          <label class="flex items-center gap-2 text-xs text-zinc-400">
            <input
              type="checkbox"
              name="git_init"
              value="true"
              checked={@register_form["git_init"] == "true"}
            /> Run <code class="font-mono">git init</code>
            if not already a git repo
          </label>
          <button class="rounded bg-cyan-700 px-3 py-1 text-sm" type="submit">
            Profile &amp; register
          </button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <.link navigate={~p"/projects"} class="text-cyan-400 text-sm">
          ← back to projects
        </.link>
        <div class="flex items-center justify-between">
          <h1 class="text-xl font-semibold">{@project.name}</h1>
          <div class="flex gap-2">
            <button phx-click="refresh_profile" class="rounded bg-zinc-700 px-3 py-1 text-sm">
              Re-profile
            </button>
            <.link navigate={~p"/plan"} class="rounded bg-cyan-700 px-3 py-1 text-sm">
              Plan a run
            </.link>
            <button
              phx-click="delete_project"
              phx-value-id={@project.id}
              data-confirm="Deregister this project? Historical agents/runs are kept (unscoped)."
              class="rounded bg-red-800 px-3 py-1 text-sm"
            >
              Deregister
            </button>
          </div>
        </div>

        <.repo_health project={@project} />

        <form id="command-pack-form" phx-change="set_pack" class="flex items-end gap-2 text-sm">
          <label class="flex flex-col">
            <span class="text-xs text-zinc-400">Command pack</span>
            <select name="command_pack" class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1">
              <option :for={id <- pack_ids()} value={id} selected={id == @project.command_pack}>
                {id}
              </option>
            </select>
          </label>
          <label class="flex flex-col">
            <span class="text-xs text-zinc-400">Version</span>
            <input
              name="command_pack_version"
              value={@project.command_pack_version}
              class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1 font-mono"
            />
          </label>
        </form>

        <.command_pack_panel resolved={@resolved} capabilities={@project.capabilities} />

        <div class="rounded border border-zinc-700 p-4 space-y-3">
          <div>
            <h3 class="font-semibold">Worker models</h3>
            <p class="text-xs text-zinc-500">
              The model each worker tier spawns into for this project. A tier left blank
              inherits the global default (Settings → Default Models); an override here
              changes only this project. "Reset" re-inherits the default.
            </p>
          </div>

          <form
            :for={row <- @model_rows}
            id={"project-model-#{row.category}"}
            phx-change="set_project_model"
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <input type="hidden" name="category" value={row.category} />
            <span class="w-16 text-xs font-semibold uppercase text-zinc-300">{row.category}</span>

            <select
              name="harness"
              class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
            >
              <option value="" selected={row.harness in [nil, ""]}>harness…</option>
              <option :for={h <- row.harness_options} value={h} selected={row.harness == h}>
                {h}
              </option>
            </select>

            <select
              name="provider"
              class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
              disabled={row.harness in [nil, ""]}
            >
              <option value="" selected={row.provider in [nil, ""]}>provider…</option>
              <option :for={p <- row.provider_options} value={p} selected={row.provider == p}>
                {p}
              </option>
            </select>

            <select
              name="model"
              class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1 font-mono"
              disabled={row.harness in [nil, ""]}
            >
              <option value="" selected={row.model in [nil, ""]}>no model…</option>
              <option :for={m <- row.model_options} value={m} selected={row.model == m}>{m}</option>
            </select>

            <span
              :if={row.inherited?}
              id={"project-model-#{row.category}-inherited"}
              class="rounded bg-zinc-700 px-2 py-0.5 text-xs text-zinc-300"
              title="Inherits the global default"
            >
              inherited
            </span>

            <button
              :if={not row.inherited? and row.model not in [nil, ""]}
              type="button"
              phx-click="clear_project_model"
              phx-value-category={row.category}
              class="rounded bg-zinc-700 px-2 py-0.5 text-xs"
            >
              Reset
            </button>
          </form>
        </div>

        <div class="rounded border border-zinc-700 p-4 space-y-3">
          <div>
            <h3 class="font-semibold">Stack layers</h3>
            <p class="text-xs text-zinc-500">
              Compose this project's stack — one layer per type. The selection becomes the
              "build ONLY within this stack" contract injected into every worker the
              orchestrator spawns. Manage the catalog in Settings → Stack Layers.
            </p>
          </div>

          <form
            :for={{type, options} <- @stack_layer_options}
            id={"project-stack-layer-#{type}"}
            phx-change="select_stack_layer"
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <input type="hidden" name="layer_type" value={type} />
            <span class="w-20 text-xs font-semibold uppercase text-zinc-300">{type}</span>

            <select
              name="stack_layer_id"
              class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
            >
              <option value="" selected={@selected_layer_ids[to_string(type)] in [nil, ""]}>
                none…
              </option>
              <option
                :for={layer <- options}
                value={layer.id}
                selected={@selected_layer_ids[to_string(type)] == layer.id}
              >
                {layer.name} ({layer.language})
              </option>
            </select>
          </form>

          <div>
            <div class="text-xs font-semibold uppercase text-zinc-400">Contract preview</div>
            <pre
              :if={@stack_contract != ""}
              id="project-stack-contract"
              class="mt-1 whitespace-pre-wrap rounded bg-zinc-900 p-3 text-xs text-zinc-300"
            >{@stack_contract}</pre>
            <p
              :if={@stack_contract == ""}
              id="project-stack-contract-empty"
              class="text-xs text-zinc-500"
            >
              No layers selected — workers receive no stack contract.
            </p>
          </div>
        </div>

        <div class="rounded border border-zinc-700 p-4 space-y-2">
          <div>
            <h3 class="font-semibold">Design system</h3>
            <p class="text-xs text-zinc-500">
              The UI component vocabulary + tokens injected into every UI worker's charter,
              resolved from the detected surface/framework. A builtin ships per framework; an
              active design-system plugin overrides it.
            </p>
          </div>
          <div :if={@design_system} id="project-design-system" class="text-sm space-y-1">
            <div>
              <span class="font-mono">{@design_system.name}</span>
              <span class="ml-2 rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300">
                {to_string(@design_system.source)}
              </span>
            </div>
            <div class="text-xs text-zinc-400">
              surface: {to_string(@design_system.descriptor.surface)} · framework: {@design_system.descriptor.framework} · paradigm: {to_string(
                @design_system.descriptor.paradigm
              )}
            </div>
          </div>
          <p
            :if={is_nil(@design_system)}
            id="project-design-system-empty"
            class="text-xs text-zinc-500"
          >
            No design system resolved.
          </p>
        </div>

        <div class="rounded border border-zinc-700 p-4 space-y-3">
          <div>
            <h3 class="font-semibold">Secrets</h3>
            <p class="text-xs text-zinc-500">
              Deposited values are encrypted at rest and injected into a worker's environment
              by $NAME only — the orchestrator sees the names, never the values.
            </p>
          </div>

          <ul id="project-secrets" class="space-y-1 text-sm">
            <li
              :for={secret <- @secrets}
              id={"secret-#{secret.name}"}
              class="flex items-center justify-between border-t border-zinc-800 py-1"
            >
              <span class="font-mono">${secret.name}</span>
              <span class="text-xs text-zinc-400">{mask(secret.last_four)}</span>
              <button
                phx-click="delete_secret"
                phx-value-name={secret.name}
                data-confirm={"Delete secret #{secret.name}?"}
                class="rounded bg-red-800 px-2 py-0.5 text-xs"
              >
                Delete
              </button>
            </li>
            <li :if={@secrets == []} class="text-zinc-400">
              No secrets yet — add one below.
            </li>
          </ul>

          <form
            id="project-secret-form"
            phx-submit="add_secret"
            autocomplete="off"
            class="flex flex-wrap items-end gap-2 text-sm"
          >
            <label class="flex flex-col">
              <span class="text-xs text-zinc-400">Name</span>
              <input
                name="name"
                value={@secret_form["name"]}
                placeholder="STRIPE_API_KEY"
                class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col">
              <span class="text-xs text-zinc-400">Value</span>
              <input
                type="password"
                name="value"
                value=""
                autocomplete="off"
                placeholder="secret value"
                class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
              />
            </label>
            <button class="rounded bg-cyan-700 px-3 py-1" type="submit">Save secret</button>
          </form>
        </div>

        <div class="rounded border border-zinc-700 p-4 space-y-2">
          <h3 class="font-semibold">Recent runs · total cost {format_cost(@cost)}</h3>
          <ul class="space-y-1 text-sm">
            <li :for={run <- @runs} class="flex justify-between border-t border-zinc-800 py-1">
              <span class="font-mono">{run.current_step || "—"}</span>
              <span>{run.status}</span>
              <span :if={run.worktree_branch} class="text-xs text-cyan-400">
                {run.worktree_branch}
                <span
                  :if={run.merge_status == :merged}
                  class="text-emerald-400"
                  title={"merged @ #{run.merged_sha}"}
                >
                  · merged @ {String.slice(run.merged_sha || "", 0, 7)}
                </span>
                <span :if={run.merge_status == :failed} class="text-red-400" title={run.merge_error}>
                  · merge failed
                </span>
                <span :if={is_nil(run.merge_status)} class="text-zinc-500">· unmerged</span>
              </span>
            </li>
            <li :if={@runs == []} class="text-zinc-400">No runs yet for this project.</li>
          </ul>
        </div>

        <div id="worktrees-panel" class="rounded border border-zinc-700 p-4 space-y-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="font-semibold">
              Worktrees<span :if={is_list(@worktrees)}> · {length(@worktrees)}</span>
            </h3>
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <button
                id="isolation-toggle"
                phx-click="toggle_isolation"
                title="Isolation mode for new runs on this project (click to toggle)"
                class="rounded bg-zinc-700 px-2 py-0.5"
              >
                isolation: {@project.isolation_mode} ⇄
              </button>
              <button phx-click="refresh_worktrees" class="rounded bg-zinc-700 px-2 py-0.5">
                Refresh
              </button>
              <button
                phx-click="gc_worktrees"
                data-confirm="Reclaim every MERGED worktree older than the configured GC age? Their adw/* branches are deleted too (the commits are already on the trunk)."
                class="rounded bg-zinc-700 px-2 py-0.5"
              >
                GC merged
              </button>
              <button phx-click="prune_worktrees" class="rounded bg-zinc-700 px-2 py-0.5">
                Prune registry
              </button>
            </div>
          </div>

          <p :if={is_nil(@worktrees)} class="text-sm text-zinc-400">Loading worktrees…</p>
          <p :if={@worktrees == []} class="text-sm text-zinc-400">
            No worktrees for this project.
          </p>

          <ul :if={is_list(@worktrees) and @worktrees != []} class="space-y-1 text-sm">
            <li
              :for={wt <- @worktrees}
              id={worktree_dom_id(wt)}
              class="flex flex-wrap items-center gap-2 border-t border-zinc-800 py-1"
            >
              <span class="font-mono text-cyan-400" title={wt.path}>{wt.branch}</span>
              <span :if={wt.run_status} class="text-xs text-zinc-400">{wt.run_status}</span>
              <span
                :if={wt.merge_status == :merged}
                class="text-xs text-emerald-400"
                title={"merged @ #{wt.merged_sha}"}
              >
                merged @ {String.slice(wt.merged_sha || "", 0, 7)}
              </span>
              <span :if={wt.merge_status == :failed} class="text-xs text-red-400">
                merge failed
              </span>
              <span :if={is_nil(wt.merge_status)} class="text-xs text-zinc-500">unmerged</span>
              <span
                :if={is_integer(wt.ahead)}
                class="text-xs text-zinc-400"
                title={wt.shortstat || ""}
              >
                +{wt.ahead}/−{wt.behind}
              </span>
              <span
                :if={is_nil(wt.run_id)}
                class="rounded bg-amber-900 px-1.5 text-xs text-amber-200"
                title="Present on disk/in git but no run row knows it"
              >
                orphaned
              </span>
              <span
                :if={not wt.on_disk? and not wt.in_git?}
                class="rounded bg-zinc-700 px-1.5 text-xs text-zinc-300"
                title="A run row remembers this worktree but nothing remains on disk"
              >
                missing on disk
              </span>
              <span class="ml-auto flex gap-1">
                <button
                  :if={wt.merge_status != :merged}
                  phx-click="merge_worktree"
                  phx-value-branch={wt.branch}
                  data-confirm={"Merge #{wt.branch} into the trunk?"}
                  class="rounded bg-emerald-800 px-2 py-0.5 text-xs"
                >
                  Merge
                </button>
                <button
                  phx-click="remove_worktree"
                  phx-value-branch={wt.branch}
                  data-confirm="Remove this worktree? Uncommitted files in it are lost (the branch is kept)."
                  class="rounded bg-zinc-700 px-2 py-0.5 text-xs"
                >
                  Remove
                </button>
                <button
                  phx-click="remove_worktree_branch"
                  phx-value-branch={wt.branch}
                  data-confirm="Remove this worktree AND delete its branch? Unmerged commits are destroyed."
                  class="rounded bg-red-800 px-2 py-0.5 text-xs"
                >
                  Remove + branch
                </button>
              </span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- helpers ---

  @spec pack_ids() :: [String.t()]
  defp pack_ids do
    packs = Commands.list_packs() |> Enum.map(& &1.id) |> Enum.uniq()
    Enum.uniq(["auto" | Enum.sort(packs)])
  end

  # The resolved design system for the show page's read-only card (design-system-plugins).
  # `nil` only when even the generic builtin is missing.
  @spec resolve_design(Projects.Project.t()) :: DesignResolver.t() | nil
  defp resolve_design(project) do
    case DesignResolver.resolve(project) do
      {:ok, resolved} -> resolved
      {:error, :none} -> nil
    end
  end

  # Stack-layers card assigns (stack-layers subsystem): the per-type catalog options, the
  # project's current selection keyed by type-string (one pick per type for the picker),
  # and the live contract preview. Recomputed after every selection change.
  @spec assign_stack_layers(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) ::
          Phoenix.LiveView.Socket.t()
  defp assign_stack_layers(socket, project_id) do
    by_type = StackLayers.list_layers_by_type()

    options =
      Enum.map(StackLayer.layer_types(), fn type -> {type, Map.get(by_type, type, [])} end)

    selected =
      project_id
      |> StackLayers.layers_for_project()
      |> Map.new(fn layer -> {Atom.to_string(layer.layer_type), layer.id} end)

    assign(socket,
      stack_layer_options: options,
      selected_layer_ids: selected,
      stack_contract: Contract.render(project_id)
    )
  end

  # The project's currently-selected layers of a given type-string (stack-layers subsystem).
  @spec layers_of_type(Ecto.UUID.t(), String.t()) :: [StackLayer.t()]
  defp layers_of_type(project_id, layer_type) do
    project_id
    |> StackLayers.layers_for_project()
    |> Enum.filter(&(Atom.to_string(&1.layer_type) == layer_type))
  end

  # The per-project worker roster card rows: the EFFECTIVE entry per tier (project
  # override, else inherited global default) with registry-driven option lists.
  @spec model_rows(RepoBuilder.Orchestrator.Orchestrator.t()) :: [map()]
  defp model_rows(orchestrator) do
    Enum.map(Orchestrators.agent_categories(), fn category ->
      {entry, source} = Orchestrators.effective_agent_model(orchestrator, category)
      entry = entry || %{}
      harness = entry["harness"]
      provider = entry["provider"]
      model = entry["model"]

      base = if(harness, do: Registry.orchestrator_models(harness, provider), else: [])
      model_options = if(model in [nil, "" | base], do: base, else: [model | base])

      %{
        category: category,
        harness: harness,
        provider: provider,
        model: model,
        inherited?: not is_nil(model) and source == :default,
        harness_options: Registry.known(),
        provider_options: if(harness, do: provider_options(harness), else: []),
        model_options: model_options
      }
    end)
  end

  @spec provider_options(String.t()) :: [String.t()]
  defp provider_options(harness) do
    defaults = Registry.orchestrator_defaults(harness)

    case defaults[:providers] do
      [_ | _] = providers -> providers
      _ -> [defaults[:default_provider]] |> Enum.reject(&is_nil/1)
    end
  end

  # Cascade an agent-models row change, driven by which input fired (`_target`) against
  # the tier's currently-stored entry: harness change clears provider+model; provider
  # change clears model; a no-op re-pick preserves downstream fields. Mirrors the console.
  @spec project_model_attrs(map(), map()) :: %{optional(String.t()) => String.t() | nil}
  defp project_model_attrs(%{"_target" => ["harness" | _]} = params, stored) do
    submitted = nilify(params["harness"])

    if submitted == stored[:harness] do
      %{"harness" => stored[:harness], "provider" => stored[:provider], "model" => stored[:model]}
    else
      %{"harness" => submitted, "provider" => nil, "model" => nil}
    end
  end

  defp project_model_attrs(%{"_target" => ["provider" | _]} = params, stored) do
    submitted = nilify(params["provider"])

    %{
      "harness" => nilify(params["harness"]),
      "provider" => submitted,
      "model" => if(submitted == stored[:provider], do: stored[:model], else: nil)
    }
  end

  defp project_model_attrs(params, _stored) do
    %{
      "harness" => nilify(params["harness"]),
      "provider" => nilify(params["provider"]),
      "model" => nilify(params["model"])
    }
  end

  @spec nilify(String.t() | nil) :: String.t() | nil
  defp nilify(nil), do: nil

  defp nilify(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec project_cost(Ecto.UUID.t()) :: Decimal.t()
  defp project_cost(project_id) do
    project_id
    |> Workflows.list_recent_for_project(500)
    |> Enum.reduce(Decimal.new(0), fn run, acc ->
      Decimal.add(acc, run.total_cost_usd || Decimal.new(0))
    end)
  end

  @spec format_cost(Decimal.t()) :: String.t()
  defp format_cost(%Decimal{} = cost) do
    if Decimal.equal?(cost, 0), do: "—", else: "$#{Decimal.round(cost, 4)}"
  end

  @spec stack_of(Projects.Project.t()) :: String.t()
  defp stack_of(project), do: to_string(project.stack["language"] || "unknown")

  # Masked UI hint for a secret row — last four chars only, never the value.
  @spec mask(String.t() | nil) :: String.t()
  defp mask(last_four) when is_binary(last_four) and last_four != "", do: "••••#{last_four}"
  defp mask(_last_four), do: "••••"

  # Keep only the registration form fields (string keys). The `create_dir` checkbox is
  # only present in params when ticked, so an absent key naturally reads as unchecked.
  @spec register_fields(map()) :: %{optional(String.t()) => String.t()}
  defp register_fields(params), do: Map.take(params, ["name", "root_path", "create_dir"])

  @spec path_hint(String.t()) :: String.t()
  defp path_hint(""), do: "Paste an absolute path; the profiler detects the stack on register."

  defp path_hint(path) do
    case FileBrowser.list(path) do
      {:ok, %{path: expanded}} -> "✓ #{expanded}"
      {:error, _} -> "Path not found or not a directory yet."
    end
  end

  @spec error_message(Ecto.Changeset.t()) :: String.t()
  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
