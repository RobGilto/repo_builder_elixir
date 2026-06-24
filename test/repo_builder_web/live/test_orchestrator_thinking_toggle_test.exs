defmodule RepoBuilderWeb.TestOrchestratorThinkingToggleTest do
  @moduledoc """
  Integration test for the "Show orchestrator thinking" toggle in the General
  settings tab (see
  specs/issue-be-adw-able-sdlc_planner-toggle-orchestrator-thinking.md).

  The console mirrors the tac-14 chat/events separation: the right-hand CHAT pane
  holds only the human-facing conversation (user prompts + finalized orchestrator
  text), while reasoning and tool activity live in the center EVENT STREAM. So this
  test asserts:

    * a finalized reasoning block does NOT post a chat bubble — it lands in the
      center event stream (under the THINKING category) instead, keeping the chat
      uncluttered, while the finalized response still becomes one orchestrator bubble;
    * the `#settings-thinking` toggle governs the live, in-flight streaming thinking
      bubble (the only thinking surface that remains in the chat): visible by default,
      hidden after toggling OFF (while the streaming text bubble remains), restored on
      re-toggle. The toggle is pure presentation state, so no event is dropped.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  `fake` harness (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard, Orchestrators}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "thinking-agent-#{System.unique_integer([:positive])}"

  # The chat pane is scoped to the ACTIVE orchestrator (the platform default on a
  # no-project mount), so a chat-bound turn must broadcast under its id.
  defp active_orch_agent_id do
    {:ok, default} = Orchestrators.get_or_create_default()
    "orch-#{default.id}-#{System.unique_integer([:positive])}"
  end

  # Flush the throttled streaming buffer deterministically, then drain the mailbox.
  defp flush(view) do
    send(view.pid, :flush_stream)
    render(view)
  end

  # Seed an agent the way the orchestrator will at runtime: persist it, then announce
  # it on the console's `agent_created` seam so the LiveView adds it to the rail live.
  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  test "finalized reasoning lands in the event stream, not the chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    _ = create_agent(view, uniq_name())

    # Orchestrator turns broadcast under the `"orch-…"` namespace; only those reach
    # the chat pane (worker UUIDs stay in the center event stream).
    orch_id = active_orch_agent_id()
    broadcast = fn event -> Dashboard.broadcast_event(orch_id, event) end
    broadcast.(%Event.TextDelta{harness: :fake, text: "deep thoughts", thinking?: true})
    broadcast.(%Event.TextDelta{harness: :fake, text: "hello response", thinking?: false})

    # Drain the LiveView mailbox (FIFO) before asserting on the resulting DOM.
    _ = render(view)

    # The reasoning block is NOT a chat bubble — it shows in the center event stream.
    refute has_element?(view, ".cns-bubble--thinking")
    assert has_element?(view, "#event-stream", "deep thoughts")

    # The finalized response still becomes exactly one orchestrator chat bubble.
    assert has_element?(view, ".cns-bubble--orch", "hello response")
  end

  test "the thinking toggle hides/shows the live streaming THINKING bubble", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent_id = active_orch_agent_id()

    # In-flight (partial) reasoning + response stream into separate live bubbles.
    Dashboard.broadcast_event(agent_id, %Event.TextDelta{
      harness: :fake,
      text: "pondering",
      thinking?: true,
      partial?: true
    })

    Dashboard.broadcast_event(agent_id, %Event.TextDelta{
      harness: :fake,
      text: "answer",
      thinking?: false,
      partial?: true
    })

    _ = flush(view)

    # Default ON: the live streaming thinking bubble and the text bubble both render.
    assert has_element?(view, "#streaming-think-#{agent_id}", "pondering")
    assert has_element?(view, "#streaming-text-#{agent_id}", "answer")
    assert has_element?(view, "#settings-thinking", "ON")

    # Toggle OFF: the streaming thinking bubble is filtered out; the text bubble stays.
    view |> element("#settings-thinking") |> render_click()

    refute has_element?(view, "#streaming-think-#{agent_id}")
    assert has_element?(view, "#streaming-text-#{agent_id}", "answer")
    assert has_element?(view, "#settings-thinking", "OFF")

    # Toggle back ON: the thinking bubble reappears (it was only filtered, not dropped).
    view |> element("#settings-thinking") |> render_click()

    assert has_element?(view, "#streaming-think-#{agent_id}", "pondering")
    assert has_element?(view, "#settings-thinking", "ON")
  end
end
