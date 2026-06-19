defmodule RepoBuilder.Orchestrator.TestWorkerResultReportingTest do
  @moduledoc """
  Regression test for issue-2541: the orchestrator could not read a spawned worker's
  results because `check_agent_status` dropped event payloads (`log_summary/1` kept only
  `{event_type, at}`) and exposed no field carrying the worker's final answer.

  This is a tool/data-layer fix at the `Orchestrator.Tools` boundary — the orchestrator
  reads worker output through this tool — so a `Phoenix.LiveViewTest` is not the right
  surface; this exercises the tool directly against seeded `agent_logs`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  defp worker(orch) do
    name = "scout-#{uniq()}"
    {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})
    {:ok, agent} = Agents.get_by_name_for_orchestrator(orch.id, name)
    {name, agent}
  end

  defp persist(event, agent_id),
    do: {:ok, _} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})

  test "check_agent_status surfaces the worker's final result and per-event text" do
    orch = orchestrator()
    {name, agent} = worker(orch)

    # A finished worker: a thinking delta (must be ignored), a finalized text delta,
    # then a terminal done whose raw payload carries the report (claude maps its
    # `result` frame onto the `done` payload; `Logs.event_payload/2` persists that raw).
    persist(%Event.TextDelta{harness: :fake, text: "let me think…", thinking?: true}, agent.id)

    persist(
      %Event.TextDelta{harness: :fake, text: "scan report body", thinking?: false},
      agent.id
    )

    persist(
      %Event.Done{
        harness: :fake,
        ok: true,
        reason: :success,
        final_text: "Found 3 resumes and a cover letter.",
        raw: %{"result" => "Found 3 resumes and a cover letter."}
      },
      agent.id
    )

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})

    # The bug: final_message was absent. The fix: it carries the worker's final answer.
    assert result["final_message"] == "Found 3 resumes and a cover letter."

    # recent_events now carry a per-event text excerpt for content-bearing events.
    texts = Enum.map(result["recent_events"], & &1["text"])
    assert "scan report body" in texts
    assert "Found 3 resumes and a cover letter." in texts

    # Thinking text is never chosen as the final message.
    refute result["final_message"] == "let me think…"
  end

  test "final_message is nil for a worker with no result-bearing output" do
    orch = orchestrator()
    {name, agent} = worker(orch)

    persist(%Event.TextDelta{harness: :fake, text: "still thinking", thinking?: true}, agent.id)

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})
    assert result["final_message"] == nil
  end

  test "surfaced text is truncated to keep the tool result bounded" do
    orch = orchestrator()
    {name, agent} = worker(orch)

    long = String.duplicate("x", 5_000)

    persist(
      %Event.Done{harness: :fake, ok: true, reason: :success, raw: %{"result" => long}},
      agent.id
    )

    assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})
    assert String.ends_with?(result["final_message"], "… (truncated)")
    assert String.length(result["final_message"]) < 5_000
  end
end
