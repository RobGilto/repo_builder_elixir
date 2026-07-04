defmodule RepoBuilder.Orchestrator.Tools.Cost do
  @moduledoc """
  Cost / context-window tools: the orchestrator's own spend + context-usage
  report (`report_cost`) and the worker context controls (`compact_agent`,
  `clear_context`). Extracted verbatim from the monolithic `Orchestrator.Tools`
  (audit F3) — behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [fetch_orchestrator: 1, fetch_string: 2, normalize_reason: 1]

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Handover
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.ContextWindow
  alias RepoBuilder.Orchestrator.Tools.AgentOps
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Session

  @type result :: Shared.result()

  @doc """
  The orchestrator's own cost/context report: session status, USD rollup, token
  totals, and context-window usage (with the shared high-usage warning).
  """
  @spec report_cost(Ecto.UUID.t()) :: result()
  def report_cost(orchestrator_id) do
    with {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
      harness = orch.harness || ""
      totals = Orchestrators.token_totals(orch)
      fraction = ContextWindow.usage_fraction(totals.context, harness, orch.model)

      report = %{
        "session_id" => orch.session_id,
        "status" => to_string(orch.status),
        "cost_usd" => Decimal.to_string(orch.total_cost_usd),
        "input_tokens" => totals.input,
        "output_tokens" => totals.output,
        "total_tokens" => totals.total,
        "context_tokens" => totals.context,
        "context_window" => ContextWindow.size(harness, orch.model),
        "context_usage_pct" => Float.round(fraction * 100, 1)
      }

      {:ok, maybe_warn(report, fraction)}
    end
  end

  # Inference-only spec (mirrors `report_cost/1`): the concrete report map narrows
  # below a hand-written `map()` return under :underspecs. The high-usage threshold is
  # the SHARED `Handover.threshold/0`, so the warning and the worker wind-down agree.
  defp maybe_warn(report, fraction) do
    if Handover.over_threshold?(fraction) do
      Map.put(
        report,
        "warning",
        "context usage at #{Float.round(fraction * 100, 1)}% — compact workers nearing their limit or suggest the operator run /compact"
      )
    else
      report
    end
  end

  @doc """
  Thin sugar over `command_agent`: resolve the worker by name and dispatch the
  `/compact` slash command (both Claude and pi honor it). Reuses the command path,
  so an unknown worker returns its `{:error, ...}` unchanged.
  """
  @spec compact_agent(Ecto.UUID.t(), map()) :: result()
  def compact_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name") do
      AgentOps.command_agent(orchestrator_id, %{"name" => name, "prompt" => "/compact"})
    end
  end

  @doc """
  Fully reset a worker's context window (issue clear-context). Unlike `compact_agent`
  (which keeps a summary in-window), this reaps any live session and NULLS the
  worker's resumable `session_id`, so the next `command_agent` mints a fresh harness
  session with zero prior history. Worker scoping makes a cross-tenant clear impossible.
  """
  @spec clear_context(Ecto.UUID.t(), map()) :: result()
  def clear_context(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      # Reap any live session first so the reset leaves no orphaned child; a worker
      # with no live session returns `{:error, :not_found}`, ignored.
      _ = Session.Supervisor.stop_session(worker.id)
      # Null the resumable session so the next command_agent takes the fresh-session branch.
      _ = Agents.set_session(worker.id, nil)

      case Agents.set_status(worker.id, :idle) do
        {:ok, idle} ->
          _ = Dashboard.broadcast_agent_updated(idle)
          {:ok, %{"status" => "cleared", "id" => worker.id, "name" => worker.name}}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end
end
