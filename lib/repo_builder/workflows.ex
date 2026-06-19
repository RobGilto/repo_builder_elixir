defmodule RepoBuilder.Workflows do
  @moduledoc """
  Context for ADW definitions and runs (BUILD_PROMPT.md §7/§8). The only `Repo`
  caller for `workflows`/`workflow_runs`. `workflow_runs` is the source of truth
  for run position; cost rolling preserves the NULL (unpriced) vs 0 distinction.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Repo
  alias RepoBuilder.Workflows.{Workflow, WorkflowRun}

  # --- workflows ---

  @spec list_workflows() :: [Workflow.t()]
  def list_workflows, do: Repo.all(from(w in Workflow, order_by: [asc: w.name]))

  @spec get_workflow(Ecto.UUID.t()) :: Workflow.t() | nil
  def get_workflow(id), do: Repo.get(Workflow, id)

  @spec create_workflow(map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(params) do
    %Workflow{}
    |> Workflow.changeset(params)
    |> Repo.insert()
  end

  @spec update_workflow(Workflow.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def update_workflow(%Workflow{} = workflow, params) do
    workflow
    |> Workflow.changeset(params)
    |> Repo.update()
  end

  @spec delete_workflow(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def delete_workflow(%Workflow{} = workflow), do: Repo.delete(workflow)

  # --- runs ---

  @spec get_run(Ecto.UUID.t()) :: WorkflowRun.t() | nil
  def get_run(id), do: Repo.get(WorkflowRun, id)

  @spec create_run(map()) :: {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def create_run(params) do
    %WorkflowRun{}
    |> WorkflowRun.changeset(params)
    |> Repo.insert()
  end

  @spec update_run(WorkflowRun.t(), map()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%WorkflowRun{} = run, params) do
    run
    |> WorkflowRun.changeset(params)
    |> Repo.update()
  end

  @doc """
  Roll a step's cost into the run total, preserving the unpriced (NULL) distinction:
  adding `nil` is a no-op (stays NULL until a priced amount arrives); adding a
  `Decimal` accumulates onto `current || 0`.
  """
  @spec add_run_cost(WorkflowRun.t(), Decimal.t() | nil) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def add_run_cost(%WorkflowRun{} = run, nil), do: {:ok, run}

  def add_run_cost(%WorkflowRun{} = run, %Decimal{} = cost) do
    # Metadata carries the scope keys so Budget.Guard (issue-budget-guardrails) can
    # attribute this spend to the {:global} and {:workflow, run_id} scopes; the
    # alert-only Telemetry.Alerting consumer still reads `run_id` unchanged.
    :telemetry.execute([:repo_builder, :cost, :recorded], %{amount: Decimal.to_float(cost)}, %{
      run_id: run.id,
      workflow_run_id: run.id,
      workflow_id: run.workflow_id,
      orchestrator_id: nil
    })

    current = run.total_cost_usd || Decimal.new(0)
    update_run(run, %{total_cost_usd: Decimal.add(current, cost)})
  end

  @doc "A run's accumulated authoritative cost as a `Decimal` (0 when unpriced/unknown)."
  @spec run_cost(Ecto.UUID.t()) :: Decimal.t()
  def run_cost(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      %WorkflowRun{total_cost_usd: %Decimal{} = cost} -> cost
      _ -> Decimal.new(0)
    end
  end

  @doc "Runs that are still in flight (no live Runner survives a restart) — the resume reconciler's input (M5)."
  @spec list_unfinished_runs() :: [WorkflowRun.t()]
  def list_unfinished_runs do
    Repo.all(from(r in WorkflowRun, where: r.status in [:queued, :running]))
  end

  @doc """
  The most recent runs (dashboard swimlane seeding). Runs soft-hidden by the console
  CLEAR action are skipped unless `include_hidden?` is true (the settings "show hidden"
  troubleshooting toggle).
  """
  @spec list_recent_runs(pos_integer(), boolean()) :: [WorkflowRun.t()]
  def list_recent_runs(limit \\ 50, include_hidden? \\ false) do
    query =
      if include_hidden? do
        from(r in WorkflowRun, order_by: [desc: r.updated_at], limit: ^limit)
      else
        from(r in WorkflowRun,
          where: r.hidden == false,
          order_by: [desc: r.updated_at],
          limit: ^limit
        )
      end

    Repo.all(query)
  end

  @doc """
  Soft-hide every FINISHED (succeeded/failed/cancelled) run — the console "CLEAR
  finished workflows" action. Running/queued runs are untouched. Persists the cleared
  state (rows are NOT deleted; revealed by the "show hidden" toggle). Returns the count.
  """
  @spec hide_finished_runs() :: non_neg_integer()
  def hide_finished_runs do
    {count, _} =
      from(r in WorkflowRun,
        where: r.hidden == false and r.status in [:succeeded, :failed, :cancelled]
      )
      |> Repo.update_all(set: [hidden: true])

    count
  end

  @doc """
  Release (permanently un-hide) EVERY soft-hidden workflow_runs row (any status) — the
  inverse of `hide_finished_runs/0` and the console "Release hidden logs & workflows"
  action. Cleared finished runs return to the swimlane view for good; already-visible
  runs are untouched. Returns the count released.
  """
  @spec release_hidden_runs() :: non_neg_integer()
  def release_hidden_runs do
    {count, _} =
      from(r in WorkflowRun, where: r.hidden == true)
      |> Repo.update_all(set: [hidden: false])

    count
  end

  # --- per-step observability (BUILD_PROMPT.md §7/§9) ---

  @type step_status :: :pending | :running | :succeeded | :failed | :cancelled

  @type step_progress :: %{
          name: String.t(),
          status: step_status(),
          cost_usd: String.t() | nil,
          started_at: String.t() | nil,
          finished_at: String.t() | nil
        }

  @type progress :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          current: String.t() | nil,
          steps: [step_progress()]
        }

  @doc """
  Read-modify-write merge of one step's attributes into the run's `step_states`
  (per-step observability), preserving sibling steps. `attrs` carry the per-step
  `status`/`started_at`/`finished_at`/`cost_usd`; keys are stringified and merged
  onto any existing entry for `step_name`. Cost stays a display string here — it
  never re-enters the run's Decimal accumulation (`add_run_cost/2` owns that).
  """
  @spec put_step_state(WorkflowRun.t(), String.t(), map()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def put_step_state(%WorkflowRun{} = run, step_name, attrs) when is_binary(step_name) do
    existing = Map.get(run.step_states, step_name, %{})
    merged = Map.merge(existing, stringify_keys(attrs))
    new_states = Map.put(run.step_states, step_name, merged)
    update_run(run, %{step_states: new_states})
  end

  @doc """
  A typed per-step view of a run, ordered by the run's workflow `steps`. Folds in
  `step_states` (default `:pending` for an unstarted step), counts `completed` as the
  number of `:succeeded` steps, and reports `current` as the run's `current_step`.
  Authoritative and branching-safe (no double counting).
  """
  @spec run_progress(WorkflowRun.t()) :: progress()
  def run_progress(%WorkflowRun{} = run) do
    names = step_names(run)
    states = run.step_states

    steps = Enum.map(names, &step_progress(&1, Map.get(states, &1, %{})))
    completed = Enum.count(steps, &(&1.status == :succeeded))

    %{
      total: length(names),
      completed: completed,
      current: run.current_step,
      steps: steps
    }
  end

  @spec step_names(WorkflowRun.t()) :: [String.t()]
  defp step_names(%WorkflowRun{workflow_id: workflow_id}) do
    case workflow_id && get_workflow(workflow_id) do
      %Workflow{steps: steps} -> Enum.map(steps, &Map.get(&1, "name"))
      _ -> []
    end
  end

  @spec step_progress(String.t(), map()) :: step_progress()
  defp step_progress(name, state) do
    %{
      name: name,
      status: parse_step_status(state["status"]),
      cost_usd: state["cost_usd"],
      started_at: state["started_at"],
      finished_at: state["finished_at"]
    }
  end

  # Map the persisted (string) status to the typed atom; an absent/unknown status is
  # `:pending` (never `String.to_atom/1` on stored data — AGENTS.md).
  @spec parse_step_status(term()) :: step_status()
  defp parse_step_status("running"), do: :running
  defp parse_step_status("succeeded"), do: :succeeded
  defp parse_step_status("failed"), do: :failed
  defp parse_step_status("cancelled"), do: :cancelled
  defp parse_step_status(_other), do: :pending

  @spec stringify_keys(map()) :: %{optional(String.t()) => term()}
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
