defmodule RepoBuilderWeb.TestAgentHandoverTest do
  @moduledoc """
  LiveView proof for the graceful worker handover (issue graceful-agent-handover): when
  a worker returns a `:handover <path>` signal, the platform self-deletes it and resumes
  the orchestrator. The console must drop the retired worker's rail card (via the real
  `Dashboard.broadcast_agent_deleted` the `delete_agent` tool emits) and reflect the queued
  handover resume in the orchestrator queue strip.

  Uses the REAL `Tools.call/3` (so the delete actually fires + broadcasts) with a
  controllable `:starter` for the orchestrator resume turn (no real harness).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrators

  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{System.unique_integer([:positive])}"}
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )

    {:ok, orch} = Orchestrators.get_or_create_default()
    start_supervised!({Queue, orchestrator_id: orch.id, starter: controllable_starter(self())})
    %{orch: orch}
  end

  test "a handover signal removes the worker's rail card and queues a handover resume", %{
    conn: conn,
    orch: orch
  } do
    {:ok, worker} =
      Agents.create_worker(orch.id, %{
        "name" => "scout-#{System.unique_integer([:positive])}",
        "harness" => "fake",
        "provider" => "anthropic",
        "model" => "fake-model",
        "config" => %{"winding_down" => true}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    # The worker's rail card is present on mount.
    assert has_element?(view, "#agent-#{worker.id}")

    # The worker returns with a handover signal.
    Dashboard.broadcast_worker_terminal(orch.id, %{
      worker_id: worker.id,
      name: worker.name,
      ok?: true,
      context_tokens: 0,
      final_text: "all handed over.\n:handover ai_docs/scout-handover.md"
    })

    # The platform retired the worker → its rail card disappears.
    assert wait_until(fn -> not has_element?(view, "#agent-#{worker.id}") end)
    assert Agents.get_agent(worker.id) == nil

    # And the orchestrator is re-engaged with the handover resume (queue strip shows Busy).
    assert_receive {:turn_started, prompt, _resume}, 1_000
    assert prompt =~ "ai_docs/scout-handover.md"
    assert wait_until(fn -> has_element?(view, "#orchestrator-queue", "Busy") end)
  end
end
