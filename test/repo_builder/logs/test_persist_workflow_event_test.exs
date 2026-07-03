defmodule RepoBuilder.Logs.PersistWorkflowEventTest do
  @moduledoc """
  Context unit tests for `RepoBuilder.Logs.persist_workflow_event/2`
  (specs/issue-custom-adw-observability…) — the durable `workflow_run_id` scope that gives
  in-app custom-ADW step sessions reconnect/late-connect observability parity with worker
  and orchestrator sessions.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs
  alias RepoBuilder.Workflows

  defp run_fixture do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "wf-#{System.unique_integer([:positive])}",
        type: "custom",
        steps: [%{"name" => "build", "harness" => "fake"}]
      })

    {:ok, run} = Workflows.create_run(%{workflow_id: workflow.id, status: :running})
    run
  end

  test "persists with workflow_run_id set and agent_id/orchestrator_id nil" do
    run = run_fixture()

    {:ok, log} =
      Logs.persist_workflow_event(
        %Event.TextDelta{harness: :fake, text: "step output"},
        %{workflow_run_id: run.id, session_id: "wf-#{run.id}-build"}
      )

    assert log.workflow_run_id == run.id
    assert log.agent_id == nil
    assert log.orchestrator_id == nil
    assert log.session_id == "wf-#{run.id}-build"
    assert log.event_type == :text_delta
  end

  test "redacts a secret in raw before it reaches the persisted payload" do
    run = run_fixture()

    {:ok, log} =
      Logs.persist_workflow_event(
        %Event.ToolCall{
          harness: :fake,
          name: "call_api",
          input: %{"url" => "https://example.com"},
          raw: %{"api_key" => "sk-super-secret"}
        },
        %{workflow_run_id: run.id, session_id: "wf-#{run.id}-build"}
      )

    refute inspect(log.payload) =~ "sk-super-secret"
  end

  test "round-trips through list_recent_global/2" do
    run = run_fixture()

    {:ok, _log} =
      Logs.persist_workflow_event(
        %Event.TextDelta{harness: :fake, text: "hello from workflow step"},
        %{workflow_run_id: run.id, session_id: "wf-#{run.id}-build"}
      )

    rows = Logs.list_recent_global(200, false)
    assert Enum.any?(rows, &(&1.workflow_run_id == run.id))
  end

  test "returns {:error, changeset} instead of raising when the workflow_run_id FK is violated" do
    assert {:error, %Ecto.Changeset{}} =
             Logs.persist_workflow_event(
               %Event.TextDelta{harness: :fake, text: "orphan"},
               %{workflow_run_id: Ecto.UUID.generate(), session_id: "wf-missing-build"}
             )
  end
end
