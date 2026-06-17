defmodule RepoBuilderWeb.TestOrchestratorThinkingToggleTest do
  @moduledoc """
  Integration test for the "Show orchestrator thinking" toggle in the General
  settings tab (see
  specs/issue-be-adw-able-sdlc_planner-toggle-orchestrator-thinking.md).

  Drives canonical `Event.TextDelta` (reasoning + response) over the `Dashboard`
  PubSub seam and asserts the chat-panel `.cns-bubble--thinking` is visible by
  default, hidden after toggling `#settings-thinking` OFF (while the response bubble
  remains), and restored on re-toggle. The toggle is pure presentation state, so no
  underlying event is dropped.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  `fake` harness (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "thinking-agent-#{System.unique_integer([:positive])}"

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  test "the thinking toggle hides/shows orchestrator THINKING bubbles in the chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    broadcast = fn event -> Dashboard.broadcast_event(agent.id, event) end
    broadcast.(%Event.TextDelta{harness: :fake, text: "deep thoughts", thinking?: true})
    broadcast.(%Event.TextDelta{harness: :fake, text: "hello response", thinking?: false})

    # Drain the LiveView mailbox (FIFO) before asserting on the resulting DOM.
    _ = render(view)

    # Default ON: both the thinking bubble and the response bubble render.
    assert has_element?(view, ".cns-bubble--thinking")
    assert has_element?(view, ".cns-bubble--orch", "hello response")
    assert has_element?(view, "#settings-thinking", "ON")

    # Toggle OFF: thinking is filtered out of the chat; the response remains.
    view |> element("#settings-thinking") |> render_click()

    refute has_element?(view, ".cns-bubble--thinking")
    assert has_element?(view, ".cns-bubble--orch", "hello response")
    assert has_element?(view, "#settings-thinking", "OFF")

    # Toggle back ON: the thinking bubble reappears (it was only filtered, not dropped).
    view |> element("#settings-thinking") |> render_click()

    assert has_element?(view, ".cns-bubble--thinking")
    assert has_element?(view, "#settings-thinking", "ON")
  end
end
