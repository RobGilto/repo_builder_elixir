defmodule RepoBuilder.Workers.CronTrigger do
  @moduledoc """
  Cron-triggered ADW launch (BUILD_PROMPT.md §7). A crontab entry schedules this
  worker with `args: %{"workflow_name" => "..."}`; `perform/1` durably enqueues that
  workflow (creates the run + first `StepWorker` job) so the run survives a node
  restart. Never-valid args (no/unknown workflow) return `{:cancel, _}` — no retry storm.

  Example crontab entry (config/config.exs):

      {"0 3 * * *", RepoBuilder.Workers.CronTrigger, args: %{"workflow_name" => "nightly-adw"}}
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.Workflows

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: trigger(Map.get(args, "workflow_name"))

  @doc "Durably trigger the named workflow (exposed for testing)."
  @spec trigger(String.t() | nil) :: :ok | {:cancel, term()} | {:error, term()}
  def trigger(name) when is_binary(name) do
    case Enum.find(Workflows.list_workflows(), &(&1.name == name)) do
      nil ->
        {:cancel, :workflow_not_found}

      workflow ->
        case WorkflowEngine.enqueue_workflow(workflow, %{}) do
          {:ok, _run_id} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def trigger(_name), do: {:cancel, :no_workflow_name}
end
