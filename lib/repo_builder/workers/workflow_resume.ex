defmodule RepoBuilder.Workers.WorkflowResume do
  @moduledoc """
  Crash-resume reconciler (BUILD_PROMPT.md §7). Runs periodically (Oban Cron) and
  on boot: every `workflow_runs` row still `:queued`/`:running` has no live `Runner`
  after a node restart, so we re-enqueue its NEXT durable step (keyed off
  `current_step`) via `StepWorker`.

  This is idempotent: `StepWorker`'s unique key `{workflow_run_id, step_name}` means a
  re-enqueue for a step already available/scheduled/executing is deduped — so resume
  can run as often as the cron fires without double-running a step.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias RepoBuilder.Workers.StepWorker
  alias RepoBuilder.Workflows

  @impl Oban.Worker
  def perform(_job) do
    _ = reconcile()
    :ok
  end

  @doc "Re-enqueue the current durable step for every unfinished run. Returns the count enqueued."
  @spec reconcile() :: non_neg_integer()
  def reconcile do
    Workflows.list_unfinished_runs()
    |> Enum.reduce(0, fn run, enqueued ->
      case run.current_step do
        step when is_binary(step) ->
          {:ok, _job} = StepWorker.enqueue(run.id, step)
          enqueued + 1

        _ ->
          enqueued
      end
    end)
  end
end
