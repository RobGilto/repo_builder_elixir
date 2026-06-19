defmodule RepoBuilderWeb.TestOrchestratorCostSumTest do
  @moduledoc """
  Proves the three console cost badges reconcile (issue cost-sum-adw-local):
  `Σ worker agent_costs + orchestrator_cost == header total cost`, continuously — on a
  fresh mount (seed path), after live events routed by owner, and after a worker is
  removed (Option A reconciliation matching the `agent_logs.agent_id` cascade delete).

  Before the fix the ORCHESTRATOR panel borrowed the grand-total `@cost`, so it equalled
  the header and the per-agent cards looked double-counted.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard, Orchestrators, Repo}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.{AgentLog, Usage}

  defp uniq, do: System.unique_integer([:positive])

  defp worker(orch_id) do
    {:ok, agent} =
      Agents.create_worker(orch_id, %{
        name: "worker-#{uniq()}",
        harness: "claude",
        provider: "anthropic",
        model: "claude-opus-4-8"
      })

    agent
  end

  # Insert a priced usage log keyed by EITHER a worker (`agent_id:`) or the orchestrator
  # itself (`orchestrator_id:`) — the XOR ownership the schema enforces.
  defp seed_log(owner, cost) do
    base = %AgentLog{
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: "claude",
      provider: "anthropic",
      model: "claude-opus-4-8",
      hidden: false,
      usage: %Usage{input_tokens: 100, output_tokens: 100, cost_usd: Decimal.new(cost)}
    }

    Repo.insert!(struct(base, owner))
  end

  defp dec(s), do: Decimal.new(s)

  test "Σ worker costs + orchestrator cost == header total, on seed, live, and after removal",
       %{conn: conn} do
    {:ok, orch} = Orchestrators.get_or_create_default()
    w1 = worker(orch.id)
    w2 = worker(orch.id)

    # Seed disjoint priced logs: two workers + the orchestrator's own turn.
    seed_log([agent_id: w1.id], "0.10")
    seed_log([agent_id: w2.id], "0.20")
    seed_log([orchestrator_id: orch.id], "0.05")

    {:ok, view, _html} = live(conn, ~p"/")
    state = fn -> :sys.get_state(view.pid).socket.assigns end

    # --- Seed path: header total includes orchestrator-own spend, invariant holds. ---
    a = state.()
    assert Decimal.equal?(a.orchestrator_cost, dec("0.05"))

    workers_sum =
      a.agents
      |> Enum.map(&Map.get(a.agent_costs, &1.id, Decimal.new(0)))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    assert Decimal.equal?(Decimal.add(workers_sum, a.orchestrator_cost), a.cost)
    # Orchestrator badge value differs from the header total (guards the regression).
    refute Decimal.equal?(a.orchestrator_cost, a.cost)

    # The three rendered badges: orchestrator panel ≠ header when a worker has cost.
    assert render(element(view, "#stat-cost")) =~ "$0.35"
    assert render(element(view, "#command-panel")) =~ "$0.05"

    # --- Live routing: an orchestrator turn (synthetic "orch-…" id) lands on the panel. ---
    Dashboard.broadcast_event("orch-#{orch.id}-1", %Event.Done{
      harness: :claude,
      ok: true,
      reason: :success,
      cost_usd: 0.05
    })

    assert wait_orchestrator_cost(view, dec("0.10"))

    # --- Worker removal (Option A): subtract the removed worker, invariant still holds. ---
    send(view.pid, {:agent_deleted, w2})
    _ = render(view)

    b = state.()
    refute render(view) =~ "#agent-#{w2.id}"
    refute Map.has_key?(b.agent_costs, w2.id)

    workers_sum_b =
      b.agents
      |> Enum.map(&Map.get(b.agent_costs, &1.id, Decimal.new(0)))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    assert Decimal.equal?(Decimal.add(workers_sum_b, b.orchestrator_cost), b.cost)
    # Total was 0.40 (0.35 seed + 0.05 live orch turn); removing w2's 0.20 ⇒ 0.20.
    assert Decimal.equal?(b.cost, dec("0.20"))
  end

  defp wait_orchestrator_cost(view, expected, attempts \\ 50) do
    cost = :sys.get_state(view.pid).socket.assigns.orchestrator_cost

    cond do
      match?(%Decimal{}, cost) and Decimal.equal?(cost, expected) ->
        true

      attempts > 0 ->
        Process.sleep(20) && wait_orchestrator_cost(view, expected, attempts - 1)

      true ->
        flunk(
          "orchestrator_cost never reached #{Decimal.to_string(expected)} (got #{inspect(cost)})"
        )
    end
  end
end
