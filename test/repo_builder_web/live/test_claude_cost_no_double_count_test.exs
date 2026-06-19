defmodule RepoBuilderWeb.TestClaudeCostNoDoubleCountTest do
  @moduledoc """
  Regression test for issue-claude-cost: a claude terminal `result` frame must be
  counted exactly ONCE by the live cost badge. Before the fix, the same
  `total_cost_usd` was stamped on both the terminal `Event.Usage` and the
  `Event.Done`, and the console accumulated cost additively on both handlers — so a
  $0.10 run showed $0.20. After the fix (cost on `Done` only), it shows $0.10.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  fake/claude harnesses registered in `config/test.exs`.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Claude

  @model "claude-opus-4-5"

  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "claude", provider: "anthropic"})
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

  test "a claude terminal cost is counted once in the agent-card badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, "claude-cost-#{System.unique_integer([:positive])}")

    frame = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "total_cost_usd" => 0.10,
      "usage" => %{"input_tokens" => 1_000, "output_tokens" => 1_000}
    }

    ctx = %{harness: :claude, model: @model, price_table: %{@model => 30.0}}
    assert {:ok, events} = Claude.normalize(frame, ctx)

    # Broadcast in harness order: terminal Usage, then Done.
    Enum.each(events, fn event -> Dashboard.broadcast_event(agent.id, event) end)

    assert wait_until(fn ->
             render(element(view, "#agent-#{agent.id}")) =~ "$0.10"
           end)

    refute render(element(view, "#agent-#{agent.id}")) =~ "$0.20"
  end
end
