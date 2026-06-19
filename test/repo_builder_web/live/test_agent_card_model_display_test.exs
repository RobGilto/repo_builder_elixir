defmodule RepoBuilderWeb.TestAgentCardModelDisplayTest do
  @moduledoc """
  Proves the agent rail card footer shows the agent's MODEL (e.g. `claude-opus-4-8`),
  not its harness (issue show-adw-the). The `agent_card` component already renders
  `{@model || @harness || "—"}`; the bug was the call site never forwarding
  `model={agent.model}`. Fails before that one-line wiring, passes after.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Orchestrators}

  defp uniq_name, do: "model-agent-#{System.unique_integer([:positive])}"

  test "the agent card footer shows the model, not the harness", %{conn: conn} do
    {:ok, orch} = Orchestrators.get_or_create_default()

    {:ok, agent} =
      Agents.create_worker(orch.id, %{
        name: uniq_name(),
        harness: "claude",
        provider: "anthropic",
        model: "claude-opus-4-8"
      })

    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, {:agent_created, agent})
    _ = render(view)

    card = render(element(view, "#agent-#{agent.id}"))
    assert card =~ "claude-opus-4-8"
  end
end
