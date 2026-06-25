defmodule RepoBuilderWeb.TestConversationHistorySwitchTest do
  @moduledoc """
  Per-project conversation history (issue-conversation-history-scope): the console's
  right-hand chat pane follows the project switcher. Selecting a project reloads THAT
  orchestrator's own conversation; a background (non-active) orchestrator's live
  `TextDelta` broadcast never bleeds into the visible chat. References the stable
  `#chat-log` container, not raw HTML.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Logs, Orchestrators, Projects}
  alias RepoBuilder.Harness.Event

  # The console opens scoped to the platform/home project (`Projects.default_project/0`,
  # the earliest project in the sandbox); there is no blank "all / platform" option, so
  # switching is always between concrete projects by id.

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    n = uniq()

    {:ok, project} =
      Projects.create_project(%{"name" => "conv-#{n}", "root_path" => "/tmp/conv-#{n}"})

    project
  end

  # Persist a distinct two-line conversation (operator turn + orchestrator reply) for
  # one orchestrator via the durable `Logs` persist functions.
  defp seed_conversation(orchestrator_id, operator_text, reply_text) do
    {:ok, _} = Logs.persist_operator_message(operator_text, %{orchestrator_id: orchestrator_id})

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :claude, text: reply_text, raw: %{"text" => reply_text}},
        %{orchestrator_id: orchestrator_id, session_id: "s-#{uniq()}"}
      )

    :ok
  end

  defp chat_pane(view), do: view |> element("#chat-log") |> render()

  test "switching projects swaps the visible conversation; the home project restores it", %{
    conn: conn
  } do
    # The earliest project is the mount default (`Projects.default_project/0`).
    project_a = project_fixture()
    project_b = project_fixture()

    {:ok, orch_a} = Orchestrators.get_or_create_for_project(project_a.id)
    {:ok, orch_b} = Orchestrators.get_or_create_for_project(project_b.id)

    seed_conversation(orch_a.id, "hello A", "reply A")
    seed_conversation(orch_b.id, "hello B", "reply B")

    {:ok, view, _html} = live(conn, ~p"/")

    # Mount defaults to project A (the home/earliest project): its conversation only.
    pane = chat_pane(view)
    assert pane =~ "hello A"
    assert pane =~ "reply A"
    refute pane =~ "reply B"

    # Switch to project B: the inverse — B's conversation, none of A's.
    render_change(view, "select_project", %{"project_id" => project_b.id})
    pane = chat_pane(view)
    assert pane =~ "hello B"
    assert pane =~ "reply B"
    refute pane =~ "reply A"

    # Back to the home project A (by id): A's conversation returns.
    render_change(view, "select_project", %{"project_id" => project_a.id})
    pane = chat_pane(view)
    assert pane =~ "reply A"
    refute pane =~ "reply B"
  end

  test "a background orchestrator's live TextDelta never enters the active chat pane", %{
    conn: conn
  } do
    project_a = project_fixture()
    project_b = project_fixture()

    {:ok, orch_a} = Orchestrators.get_or_create_for_project(project_a.id)
    {:ok, orch_b} = Orchestrators.get_or_create_for_project(project_b.id)

    seed_conversation(orch_a.id, "hello A", "reply A")

    {:ok, view, _html} = live(conn, ~p"/")
    render_change(view, "select_project", %{"project_id" => project_a.id})

    # Broadcast a finalized turn from the BACKGROUND orchestrator B on the topic the
    # console subscribes to, using B's `"orch-<id>-<n>"` agent_id convention.
    Dashboard.broadcast_event(
      "orch-#{orch_b.id}-1",
      %Event.TextDelta{harness: :claude, text: "leak from B", raw: %{"text" => "leak from B"}},
      nil
    )

    # `render/1` forces a synchronous round-trip, draining the broadcast handle_info.
    _ = render(view)

    pane = chat_pane(view)
    assert pane =~ "reply A"
    refute pane =~ "leak from B"

    # Switching to B then surfaces B's own live message via the active gate (memory kept).
    render_change(view, "select_project", %{"project_id" => project_b.id})

    Dashboard.broadcast_event(
      "orch-#{orch_b.id}-2",
      %Event.TextDelta{harness: :claude, text: "live B now", raw: %{"text" => "live B now"}},
      nil
    )

    _ = render(view)
    assert chat_pane(view) =~ "live B now"
  end
end
