defmodule RepoBuilderWeb.WorkflowLive do
  @moduledoc """
  Per-workflow-run view (BUILD_PROMPT.md §9). Loads run status/current-step/cost via
  `assign_async` (so the connected mount renders a loading placeholder), and updates
  live from the runner's `{:workflow_update, run}` broadcasts.
  """
  use RepoBuilderWeb, :live_view

  import RepoBuilderWeb.DashboardComponents

  alias Phoenix.LiveView.AsyncResult
  alias RepoBuilder.{Dashboard, Workflows}

  @impl true
  def mount(%{"id" => run_id}, _session, socket) do
    if connected?(socket), do: :ok = Dashboard.subscribe_workflow(run_id)

    socket =
      socket
      |> assign(:run_id, run_id)
      |> assign_async(:run, fn -> {:ok, %{run: load_run(run_id)}} end)

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_update, run}, socket) do
    {:noreply, assign(socket, :run, AsyncResult.ok(socket.assigns.run, run_info(run)))}
  end

  @spec load_run(String.t()) :: map() | nil
  defp load_run(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         %Workflows.WorkflowRun{} = run <- Workflows.get_run(uuid) do
      run_info(run)
    else
      _ -> nil
    end
  end

  # Inference-only spec — the concrete run-info map narrows below a hand-written
  # `map()` contract, which Dialyzer rejects as a supertype under :underspecs.
  defp run_info(run) do
    progress = Workflows.run_progress(run)

    %{
      status: run.status,
      current_step: run.current_step,
      cost: run.total_cost_usd,
      artifacts: run.artifacts,
      steps: progress.steps,
      completed: progress.completed,
      total: progress.total
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <h1 class="text-xl font-semibold">Workflow run <code>{@run_id}</code></h1>

        <.async_result :let={run} assign={@run}>
          <:loading>Loading run…</:loading>
          <:failed :let={_reason}>Could not load run.</:failed>

          <div :if={run} class="space-y-2">
            <div class="flex items-center gap-3">
              <span class="font-medium">Status:</span>
              <.swimlane_row
                id={@run_id}
                label={run.current_step || "—"}
                status={run.status}
                kind={:workflow}
              />
              <.cost_badge cost={run.cost} />
            </div>

            <div>
              <span class="font-medium">Steps ({run.completed}/{run.total}):</span>
              <ul class="list-disc pl-6 font-mono text-sm">
                <li :for={step <- run.steps}>
                  {step.name}: {step.status}
                  <span :if={step.cost_usd} class="text-base-content/60">(${step.cost_usd})</span>
                </li>
              </ul>
            </div>

            <div>
              <span class="font-medium">Artifacts:</span>
              <ul class="list-disc pl-6 font-mono text-sm">
                <li :for={{step, output} <- run.artifacts}>{step}: {inspect(output)}</li>
              </ul>
            </div>
          </div>

          <div :if={is_nil(run)}>Run not found.</div>
        </.async_result>
      </div>
    </Layouts.app>
    """
  end
end
