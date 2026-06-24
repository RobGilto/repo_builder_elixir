defmodule RepoBuilderWeb.PlanningLive do
  @moduledoc """
  The Planning-Mode Wizard (agentic-layer adaptor, Phase 6): a guided, multi-step
  LiveView at `/plan` that takes the operator from project + goal to a previewed, costed,
  launched ADW run, persisting a durable Plan artifact. It composes existing engines
  (Catalog, Commands.Resolver, Planner, ContextWindow, WorkflowEngine); it invents no new
  execution path. `/plans/:id` renders a persisted plan as a durable, read-only artifact.

  Steps: (1) pick project → (2) state goal (intent classified) → (3) workflow/harness/
  model/budget → (4) preview resolved steps + estimate → (5) confirm → launch.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.ProjectComponents, only: [plan_preview: 1]

  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Plans
  alias RepoBuilder.Plans.Planner
  alias RepoBuilder.Projects
  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.WorkflowEngine.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       step: 1,
       projects: Projects.list_projects(),
       selected_project: nil,
       goal: "",
       intent: nil,
       workflow_type: Catalog.default_type(),
       harness: "fake",
       model: "",
       budget_cap: "",
       preview: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params), do: assign(socket, page_title: "Plan a run")

  defp apply_action(socket, :show, %{"id" => id}) do
    case Plans.fetch_plan(id) do
      {:ok, plan} ->
        assign(socket,
          page_title: "Plan",
          plan: plan,
          project: Projects.get_project(plan.project_id)
        )

      {:error, :not_found} ->
        socket |> put_flash(:error, "Plan not found") |> push_navigate(to: ~p"/plan")
    end
  end

  # --- wizard events ---

  @impl true
  def handle_event("pick_project", %{"project_id" => id}, socket) do
    case Projects.fetch_project(id) do
      {:ok, project} ->
        {:noreply,
         assign(socket,
           selected_project: project,
           harness: project.default_harness || "fake",
           budget_cap: cap_string(project.budget_cap_usd),
           step: 2
         )}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: "Pick a project")}
    end
  end

  def handle_event("set_goal", %{"goal" => goal}, socket) do
    if String.trim(goal) == "" do
      {:noreply, assign(socket, error: "State a goal")}
    else
      {:noreply,
       assign(socket, goal: goal, intent: Planner.classify_intent(goal), error: nil, step: 3)}
    end
  end

  def handle_event("set_workflow", params, socket) do
    socket =
      assign(socket,
        workflow_type: params["workflow_type"] || socket.assigns.workflow_type,
        harness: blank(params["harness"]) || socket.assigns.harness,
        model: params["model"] || "",
        budget_cap: params["budget_cap"] || ""
      )

    case Planner.resolve(%{
           project: socket.assigns.selected_project,
           goal: socket.assigns.goal,
           workflow_type: socket.assigns.workflow_type,
           harness: socket.assigns.harness,
           model: blank(socket.assigns.model)
         }) do
      {:ok, preview} -> {:noreply, assign(socket, preview: preview, error: nil, step: 4)}
      {:error, :unknown_type} -> {:noreply, assign(socket, error: "Unknown workflow type")}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: max(socket.assigns.step - 1, 1), error: nil)}
  end

  def handle_event("launch", _params, socket) do
    case launch(socket) do
      {:ok, plan} ->
        {:noreply, push_navigate(socket, to: ~p"/plans/#{plan.id}")}

      {:error, :over_cap} ->
        {:noreply, assign(socket, error: "Estimate exceeds the budget cap — blocked")}

      {:error, :no_real_harness} ->
        {:noreply,
         assign(socket,
           error:
             "This project has no real harness configured — set a default harness on " <>
               "the project before launching (the demo `fake` harness performs no work)."
         )}

      {:error, _other} ->
        {:noreply, assign(socket, error: "Launch failed")}
    end
  end

  # --- launch (reuses the existing engine path) ---

  @spec launch(Phoenix.LiveView.Socket.t()) :: {:ok, Plans.Plan.t()} | {:error, term()}
  defp launch(socket) do
    %{selected_project: project, preview: preview, goal: goal} = socket.assigns
    cap = parse_cap(socket.assigns.budget_cap)

    if over_cap?(cap, preview.estimate.estimated_cost_usd) do
      {:error, :over_cap}
    else
      # Resolve a REAL launch harness BEFORE persisting anything: refusing on a no-op
      # `fake` (or blank) harness so a "launched" run can never be a silent no-op that
      # never touches the target repo (fix planning-wizard target-repo launch).
      with {:ok, harness} <- launch_harness(preview, project),
           {:ok, plan} <- persist_plan(project, goal, preview),
           {:ok, run_id} <- start_run(project, preview, goal, harness) do
        Plans.mark_launched(plan, run_id)
      end
    end
  end

  # The harness the run actually executes on. Prefer the previewed selection, then the
  # project's configured `default_harness`; the no-op `fake` adapter (and a blank) are
  # NOT real launch harnesses — refuse rather than launch a run that does nothing.
  @spec launch_harness(Planner.preview(), Projects.Project.t()) ::
          {:ok, String.t()} | {:error, :no_real_harness}
  defp launch_harness(%{harness: harness}, %Projects.Project{default_harness: default}) do
    cond do
      real_harness?(harness) -> {:ok, harness}
      real_harness?(default) -> {:ok, default}
      true -> {:error, :no_real_harness}
    end
  end

  @spec real_harness?(term()) :: boolean()
  defp real_harness?(harness),
    do: is_binary(harness) and String.trim(harness) != "" and harness != "fake"

  @spec persist_plan(Projects.Project.t(), String.t(), Planner.preview()) ::
          {:ok, Plans.Plan.t()} | {:error, Ecto.Changeset.t()}
  defp persist_plan(project, goal, preview) do
    Plans.create_plan(%{
      "project_id" => project.id,
      "goal" => goal,
      "workflow_type" => preview.workflow_type,
      "resolved_steps" => %{"steps" => preview.steps},
      "estimate" => preview.estimate,
      "status" => "draft"
    })
  end

  @spec start_run(Projects.Project.t(), Planner.preview(), String.t(), String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  defp start_run(project, preview, goal, harness) do
    name = "plan-#{preview.workflow_type}-#{System.unique_integer([:positive])}"

    with {:ok, workflow} <-
           WorkflowEngine.create_workflow_of_type(name, preview.workflow_type, harness),
         {:ok, run_id, _pid} <-
           WorkflowEngine.start_workflow(workflow,
             project_id: project.id,
             # Run each step IN the target repo (fix planning-wizard target-repo launch):
             # thread the project's working directory + isolation mode so work actually
             # materialises there instead of an ephemeral managed scratch workspace.
             cwd: project.root_path,
             isolation_mode: project.isolation_mode,
             inputs: %{"input" => goal}
           ) do
      {:ok, run_id}
    end
  end

  @spec over_cap?(Decimal.t() | nil, float()) :: boolean()
  defp over_cap?(nil, _est), do: false
  defp over_cap?(%Decimal{} = cap, est), do: Decimal.compare(Decimal.from_float(est), cap) == :gt

  @spec parse_cap(String.t()) :: Decimal.t() | nil
  defp parse_cap(value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  @spec cap_string(Decimal.t() | nil) :: String.t()
  defp cap_string(%Decimal{} = cap), do: Decimal.to_string(cap)
  defp cap_string(_), do: ""

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank(_value), do: nil

  # --- render ---

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4 max-w-3xl">
        <h1 class="text-xl font-semibold">Plan · {@plan.workflow_type}</h1>
        <p class="text-sm text-zinc-400">
          Project: {if @project, do: @project.name, else: "—"} · status:
          <span class="font-mono">{@plan.status}</span>
        </p>
        <p class="rounded bg-zinc-800 p-3 text-sm"><strong>Goal:</strong> {@plan.goal}</p>

        <ol class="list-decimal pl-5 space-y-2 text-sm">
          <li :for={step <- @plan.resolved_steps["steps"] || []}>
            <span class="font-mono">{step["name"]}</span>
            <span class="text-xs text-zinc-400">({step["provenance"]})</span>
          </li>
        </ol>

        <p class="text-xs text-zinc-400">
          est. context: {@plan.estimate["context_tokens"]} tok · est. cost: {@plan.estimate[
            "cost_band"
          ]}
        </p>
        <.link navigate={~p"/projects/#{@plan.project_id}"} class="text-cyan-400 text-sm">
          ← back to project
        </.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6 max-w-3xl">
        <.link navigate={~p"/"} class="text-cyan-400 text-sm">
          ← back to console
        </.link>
        <h1 class="text-xl font-semibold">Planning-Mode Wizard · step {@step}/4</h1>
        <p :if={@error} class="text-sm text-red-400">{@error}</p>

        <section :if={@step == 1} class="space-y-3">
          <h2 class="font-semibold">1 · Pick a project</h2>
          <form id="wizard-project" phx-submit="pick_project" class="flex items-center gap-2">
            <select name="project_id" class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1">
              <option :for={p <- @projects} value={p.id}>{p.name}</option>
            </select>
            <button class="rounded bg-cyan-700 px-3 py-1 text-sm" type="submit">Next</button>
          </form>
          <p :if={@projects == []} class="text-sm text-zinc-400">
            No projects — <.link navigate={~p"/projects"} class="text-cyan-400">register one</.link>.
          </p>
        </section>

        <section :if={@step == 2} class="space-y-3">
          <h2 class="font-semibold">2 · State the goal ({@selected_project.name})</h2>
          <form id="wizard-goal" phx-submit="set_goal" class="space-y-2">
            <textarea
              name="goal"
              rows="3"
              class="w-full rounded border border-zinc-600 bg-zinc-800 px-2 py-1 text-sm"
            >{@goal}</textarea>
            <div class="flex gap-2">
              <button type="button" phx-click="back" class="rounded bg-zinc-700 px-3 py-1 text-sm">
                Back
              </button>
              <button class="rounded bg-cyan-700 px-3 py-1 text-sm" type="submit">Next</button>
            </div>
          </form>
        </section>

        <section :if={@step == 3} class="space-y-3">
          <h2 class="font-semibold">3 · Workflow &amp; budget (intent: {@intent})</h2>
          <form id="wizard-workflow" phx-submit="set_workflow" class="space-y-2">
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Workflow type</span>
              <select
                name="workflow_type"
                class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
              >
                <option :for={t <- Catalog.types()} value={t.slug} selected={t.slug == @workflow_type}>
                  {t.label}
                </option>
              </select>
            </label>
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Harness</span>
              <select name="harness" class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1">
                <option :for={h <- harness_options()} value={h} selected={h == @harness}>{h}</option>
              </select>
            </label>
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Model (optional)</span>
              <input
                name="model"
                value={@model}
                class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
              />
            </label>
            <label class="flex flex-col text-sm">
              <span class="text-xs text-zinc-400">Budget cap USD (optional)</span>
              <input
                name="budget_cap"
                value={@budget_cap}
                class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1"
              />
            </label>
            <div class="flex gap-2">
              <button type="button" phx-click="back" class="rounded bg-zinc-700 px-3 py-1 text-sm">
                Back
              </button>
              <button class="rounded bg-cyan-700 px-3 py-1 text-sm" type="submit">Preview</button>
            </div>
          </form>
        </section>

        <section :if={@step == 4} class="space-y-3">
          <h2 class="font-semibold">4 · Preview &amp; launch</h2>
          <.plan_preview plan={@preview} />
          <div class="flex gap-2">
            <button type="button" phx-click="back" class="rounded bg-zinc-700 px-3 py-1 text-sm">
              Back
            </button>
            <button phx-click="launch" class="rounded bg-cyan-700 px-3 py-1 text-sm">
              Launch run
            </button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @spec harness_options() :: [String.t()]
  defp harness_options, do: Enum.sort(Registry.known())
end
