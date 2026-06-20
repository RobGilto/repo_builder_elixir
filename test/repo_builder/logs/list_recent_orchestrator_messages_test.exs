defmodule RepoBuilder.Logs.ListRecentOrchestratorMessagesTest do
  @moduledoc """
  Context unit tests for `RepoBuilder.Logs.list_recent_orchestrator_messages/2` (issue
  chat-history-backfill) — the orchestrator-scoped chat-pane backfill query that must
  survive a worker-dominated `agent_logs` table.

  All DB access stays behind the `RepoBuilder.Logs` context (BUILD_PROMPT.md §8); the
  tests seed through `persist_orchestrator_event/2` / `persist_event/2` and read effects
  back through the context, never `Repo` directly.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Agents
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs

  defp orch_fixture do
    {:ok, orch} =
      RepoBuilder.Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    orch
  end

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    agent
  end

  test "returns only orchestrator text_delta rows, chronological, even when workers dominate" do
    orch = orch_fixture()
    worker = agent_fixture()

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "first"},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-1"}
      )

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "second"},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-2"}
      )

    # Flood with later worker rows that would push orchestrator rows out of the global window.
    for n <- 1..250 do
      {:ok, _} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "worker #{n}"},
          %{agent_id: worker.id, session_id: "s"}
        )
    end

    rows = Logs.list_recent_orchestrator_messages(100, false)

    assert Enum.all?(rows, &(not is_nil(&1.orchestrator_id)))
    assert Enum.all?(rows, &(&1.event_type == :text_delta))
    assert Enum.map(rows, & &1.payload["text"]) == ["first", "second"]
  end

  test "excludes non-text_delta orchestrator rows" do
    orch = orch_fixture()

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.ToolCall{harness: :fake, name: "do_thing", input: %{}},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-1"}
      )

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "reply"},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-2"}
      )

    assert Logs.list_recent_orchestrator_messages(100, false)
           |> Enum.map(& &1.payload["text"]) == ["reply"]
  end

  test "respects the hidden soft-hide flag unless include_hidden? is true" do
    orch = orch_fixture()

    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "visible-then-hidden"},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-1"}
      )

    _ = Logs.hide_all_logs()

    assert Logs.list_recent_orchestrator_messages(100, false) == []

    assert Logs.list_recent_orchestrator_messages(100, true)
           |> Enum.map(& &1.payload["text"]) == ["visible-then-hidden"]
  end
end
