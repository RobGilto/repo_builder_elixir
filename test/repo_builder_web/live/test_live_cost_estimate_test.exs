defmodule RepoBuilderWeb.LiveCostEstimateTest do
  @moduledoc """
  Reproduces the "cost stays at — until the run ends" bug (issue token-drop): for the
  claude/cursor harness, per-turn `Event.Usage` carries tokens but no `cost_usd`, so the
  cost badge was dead for the whole run. The fix renders a live `~$…` estimate the instant
  token usage drops, then supersedes it with the exact `$…` authoritative amount.

  Drives the same `{:agent_event, agent_id, %Event.Usage{}}` PubSub seam the live
  `handle_info/2` already handles. `async: false` so the shared Ecto sandbox reaches
  the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "cost-agent-#{System.unique_integer([:positive])}"

  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  test "agent card shows a ~$ estimate on token drop, then the exact $ once billed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    # Before any usage the badge is the unpriced em-dash.
    refute render(element(view, "#agent-#{agent.id}")) =~ "~$"

    # A usage event with tokens but NO authoritative cost — only the token-derived estimate.
    Dashboard.broadcast_event(agent.id, %Event.Usage{
      harness: :fake,
      input_tokens: 1000,
      output_tokens: 500,
      cost_usd: nil,
      estimated_cost_usd: 0.04
    })

    assert wait_until(fn -> render(element(view, "#agent-#{agent.id}")) =~ "~$0.04" end),
           "estimate must appear the instant token usage drops (this fails before the fix)"

    # The authoritative billed amount supersedes the estimate — no `~` marker.
    Dashboard.broadcast_event(agent.id, %Event.Usage{
      harness: :fake,
      input_tokens: 1000,
      output_tokens: 500,
      cost_usd: 0.10,
      estimated_cost_usd: 0.05
    })

    assert wait_until(fn ->
             card = render(element(view, "#agent-#{agent.id}"))
             card =~ "$0.10" and not (card =~ "~$0.10")
           end)
  end

  test "the orchestrator command panel shows the orchestrator's OWN live estimate", %{conn: conn} do
    {:ok, orch} = RepoBuilder.Orchestrators.get_or_create_default()
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    # A worker estimate must NOT bleed into the ORCHESTRATOR panel (it has its own assign).
    Dashboard.broadcast_event(agent.id, %Event.Usage{
      harness: :fake,
      input_tokens: 2000,
      output_tokens: 1000,
      cost_usd: nil,
      estimated_cost_usd: 0.07
    })

    # An orchestrator-owned turn (synthetic "orch-…" id) drives the panel estimate.
    Dashboard.broadcast_event("orch-#{orch.id}-1", %Event.Usage{
      harness: :fake,
      input_tokens: 500,
      output_tokens: 250,
      cost_usd: nil,
      estimated_cost_usd: 0.03
    })

    assert wait_until(fn -> render(element(view, "#command-panel")) =~ "~$0.03" end)
    refute render(element(view, "#command-panel")) =~ "~$0.07"
  end
end
