defmodule RepoBuilderWeb.TestOperatorMessagePersistTest do
  @moduledoc """
  Regression test for the bug where the OPERATOR's own chat turns ("YOU" prompts)
  were never persisted and so vanished from the orchestrator chat pane on any
  LiveView reconnect / server restart
  (specs/issue-operator-adw-messages-sdlc_planner-persist-operator-chat-messages.md).

  Operator turns used to be pure ephemeral UI state (`push_user_message/2` appended
  to `@messages` only). The reconnect backfill rebuilds the chat from persisted rows
  (`Logs.list_recent_orchestrator_messages/2`), so the operator side of the
  conversation was lost — a one-sided transcript.

  The fix durably records each operator turn as an orchestrator-scoped `agent_logs`
  row (`event_type: :text_delta`, `payload["role"] == "operator"`). The backfill
  recognizes the marker and renders it as the distinct `:user` bubble. This test
  persists one operator turn + one orchestrator reply (and floods >200 later worker
  rows), mounts ConsoleLive, and asserts BOTH sides survive with distinct bubbles.

  `async: false` matches the other console tests (shared Ecto sandbox).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event

  test "persist_operator_message/2 round-trips an operator-marked row" do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    {:ok, log} =
      Logs.persist_operator_message("hello orchestrator", %{orchestrator_id: orch.id})

    assert log.orchestrator_id == orch.id
    assert is_nil(log.agent_id)
    assert log.event_type == :text_delta
    assert log.payload["role"] == "operator"
    assert log.payload["text"] == "hello orchestrator"

    assert Logs.list_recent_orchestrator_messages(100, false)
           |> Enum.any?(
             &(&1.payload["role"] == "operator" and &1.payload["text"] == "hello orchestrator")
           )
  end

  test "operator turn survives reconnect/restart in a distinct bubble, interleaved with the reply",
       %{conn: conn} do
    # Persist to the ACTIVE orchestrator (the platform default on a no-project mount):
    # the chat backfill is now scoped to the active brain (issue-conversation-history-scope).
    {:ok, orch} = Orchestrators.get_or_create_default()

    {:ok, worker} =
      Agents.create_agent(%{
        name: "worker-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    # The operator prompt, then the orchestrator's reply (the two sides of the dialogue).
    {:ok, _} =
      Logs.persist_operator_message("hello orchestrator", %{orchestrator_id: orch.id})

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "orchestrator reply"},
        %{orchestrator_id: orch.id, session_id: Ecto.UUID.generate()}
      )

    # Flood >200 later worker rows to prove the operator turn survives the
    # worker-dominated most-recent window (the chat-pane query is orchestrator-scoped).
    for n <- 1..250 do
      {:ok, _} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "worker output #{n}"},
          %{agent_id: worker.id, session_id: "fake-session"}
        )
    end

    {:ok, view, _html} = live(conn, ~p"/")

    # Operator turn restored in the distinct :user bubble colour.
    assert has_element?(view, ".cns-bubble--user", "hello orchestrator")
    # Orchestrator reply restored in its own bubble.
    assert has_element?(view, ".cns-bubble--orch", "orchestrator reply")
    # Control: the operator text is NOT mis-rendered as an orchestrator bubble.
    refute has_element?(view, ".cns-bubble--orch", "hello orchestrator")
    # Control: worker text never leaks into the chat pane.
    refute has_element?(view, ".cns-bubble--orch", "worker output")
  end
end
