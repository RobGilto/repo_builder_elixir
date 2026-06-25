defmodule RepoBuilderWeb.ForgeLive do
  @moduledoc """
  The Forge surface (forge-meta-artifact-generation, Phase 5): a human-in-the-loop
  LiveView at `/forge` that takes an operator from project + kind + spec to a previewed
  generator prompt, a live-streamed generation, and an activated, project-scoped plugin.

  It composes existing seams only — `Forge` (the typed context), `Forge.Workflow` (the
  deterministic ADW), and the `Plugins` install/activate lifecycle. Generation runs in a
  supervised `Task`; progress arrives over the per-artifact `forge:<id>` PubSub topic, so
  the page streams status without blocking. The generate transport is the configured
  `:forge` `:generate_runner` (a real harness session by default; the Fake-backed seam in
  CI), so the surface needs no real CLI under test.
  """
  use RepoBuilderWeb, :live_view

  alias RepoBuilder.Forge
  alias RepoBuilder.Forge.{Generator, Workflow}
  alias RepoBuilder.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Forge",
       step: :compose,
       projects: Projects.list_projects(),
       project_id: "",
       kind: "command",
       spec: "",
       preview: nil,
       artifact: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event(
        "preview",
        %{"project_id" => project_id, "kind" => kind, "spec" => spec},
        socket
      ) do
    if String.trim(spec) == "" do
      {:noreply, assign(socket, error: "Describe the tool to forge", kind: kind, spec: spec)}
    else
      case render_preview(blank(project_id), kind, spec) do
        {:ok, prompt} ->
          {:noreply,
           assign(socket,
             step: :preview,
             project_id: project_id,
             kind: kind,
             spec: spec,
             preview: prompt,
             error: nil
           )}

        {:error, _reason} ->
          {:noreply, assign(socket, error: "Unknown generator kind", kind: kind, spec: spec)}
      end
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :compose, error: nil)}
  end

  def handle_event("forge", _params, socket) do
    case Forge.request(%{
           kind: socket.assigns.kind,
           spec: socket.assigns.spec,
           project_id: blank(socket.assigns.project_id)
         }) do
      {:ok, artifact} ->
        :ok = Workflow.subscribe(artifact.id)
        start_forge(artifact)
        {:noreply, assign(socket, step: :generating, artifact: artifact, error: nil)}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: "Could not start the forge")}
    end
  end

  @impl true
  def handle_info({:forge_progress, artifact}, socket) do
    if socket.assigns.artifact && artifact.id == socket.assigns.artifact.id do
      {:noreply, assign(socket, artifact: artifact)}
    else
      {:noreply, socket}
    end
  end

  # --- helpers ---

  @spec render_preview(Ecto.UUID.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp render_preview(project_id, kind, spec) do
    case Generator.fetch(kind) do
      {:ok, def_t} ->
        Workflow.render(def_t, %Forge.Artifact{project_id: project_id, kind: kind, spec: spec})

      error ->
        error
    end
  end

  # Run the forge ADW in a supervised Task so the LiveView keeps streaming. Progress is
  # broadcast on the artifact topic the LiveView already subscribed to.
  @spec start_forge(Forge.Artifact.t()) :: :ok
  defp start_forge(artifact) do
    _ =
      Task.Supervisor.start_child(RepoBuilder.TaskSupervisor, fn ->
        Workflow.run(artifact)
      end)

    :ok
  end

  @spec blank(String.t() | nil) :: String.t() | nil
  defp blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6 max-w-3xl">
        <.link navigate={~p"/plugins"} class="text-cyan-400 text-sm">← back to plugins</.link>
        <h1 class="text-xl font-semibold">The Forge · author project tooling</h1>
        <p :if={@error} class="text-sm text-red-400">{@error}</p>

        <section :if={@step == :compose} class="space-y-3">
          <form id="forge-form" phx-submit="preview" class="space-y-3">
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Project (scope)</span>
              <select name="project_id" class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1">
                <option value="" selected={@project_id == ""}>Platform-wide</option>
                <option :for={p <- @projects} value={p.id} selected={p.id == @project_id}>
                  {p.name}
                </option>
              </select>
            </label>
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Kind</span>
              <select name="kind" class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1">
                <option :for={k <- Generator.kind_strings()} value={k} selected={k == @kind}>
                  {k}
                </option>
              </select>
            </label>
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Spec — describe the tool</span>
              <textarea
                name="spec"
                rows="4"
                class="w-full rounded border border-zinc-600 bg-zinc-800 px-2 py-1 text-sm"
              >{@spec}</textarea>
            </label>
            <button class="rounded bg-cyan-700 px-3 py-1 text-sm" type="submit">Preview prompt</button>
          </form>
        </section>

        <section :if={@step == :preview} class="space-y-3">
          <h2 class="font-semibold">Rendered generator prompt</h2>
          <pre
            id="forge-preview"
            class="max-h-96 overflow-auto rounded bg-zinc-900 p-3 text-xs whitespace-pre-wrap"
          >{@preview}</pre>
          <div class="flex gap-2">
            <button type="button" phx-click="back" class="rounded bg-zinc-700 px-3 py-1 text-sm">
              Back
            </button>
            <button phx-click="forge" class="rounded bg-amber-600 px-3 py-1 text-sm" type="button">
              Forge it →
            </button>
          </div>
        </section>

        <section :if={@step == :generating} class="space-y-3" id="forge-progress">
          <h2 class="font-semibold">Forging · {@kind}</h2>
          <p class="text-sm">
            Status: <span class="font-mono" id="forge-status">{@artifact && @artifact.status}</span>
          </p>
          <p
            :if={@artifact && @artifact.status == :installed}
            id="forge-activated"
            class="text-sm text-green-400"
          >
            Activated ✓ — {@artifact.plugin_id} is live{scope_label(@artifact)}.
          </p>
          <p :if={@artifact && @artifact.status == :failed} class="text-sm text-red-400">
            Forge failed: {@artifact.error && @artifact.error["reason"]}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @spec scope_label(Forge.Artifact.t()) :: String.t()
  defp scope_label(%{project_id: nil}), do: " platform-wide"
  defp scope_label(%{project_id: _id}), do: " for this project"
end
