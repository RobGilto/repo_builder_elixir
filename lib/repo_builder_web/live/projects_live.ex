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
  alias RepoBuilder.Projects
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
    assign(socket, page_title: "Projects", projects: Projects.list_projects(), project: nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Projects.fetch_project(id) do
      {:ok, project} ->
        socket
        |> assign(page_title: project.name, project: project)
        |> assign(resolved: Commands.resolve_all(project))
        |> assign(runs: Workflows.list_recent_for_project(project.id, 20))
        |> assign(cost: project_cost(project.id))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Project not found")
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

  def handle_event("delete_project", _params, socket) do
    {:ok, _} = Projects.delete_project(socket.assigns.project)
    {:noreply, push_navigate(socket, to: ~p"/projects")}
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
          <li :for={project <- @projects} class="rounded border border-zinc-700 p-3">
            <.link navigate={~p"/projects/#{project.id}"} class="font-medium text-cyan-400">
              {project.name}
            </.link>
            <span class="ml-2 text-xs text-zinc-400">{project.root_path}</span>
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
              data-confirm="Delete this project? Historical agents/runs are kept (unscoped)."
              class="rounded bg-red-800 px-3 py-1 text-sm"
            >
              Delete
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

        <div class="rounded border border-zinc-700 p-4 space-y-2">
          <h3 class="font-semibold">Recent runs · total cost {format_cost(@cost)}</h3>
          <ul class="space-y-1 text-sm">
            <li :for={run <- @runs} class="flex justify-between border-t border-zinc-800 py-1">
              <span class="font-mono">{run.current_step || "—"}</span>
              <span>{run.status}</span>
              <span :if={run.worktree_branch} class="text-xs text-cyan-400">
                {run.worktree_branch}
              </span>
            </li>
            <li :if={@runs == []} class="text-zinc-400">No runs yet for this project.</li>
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
