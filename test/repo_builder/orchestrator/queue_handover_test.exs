defmodule RepoBuilder.Orchestrator.QueueHandoverTest do
  @moduledoc """
  Integration tests for the Queue's graceful-handover branches (issue
  graceful-agent-handover): the three occupancy/signal-driven branches layered on the
  holding pattern — wind-down, handover+delete+resume, and force-retire — plus the
  interaction with the `seen_worker_ids` dedup.

  Drives the `Queue` with a controllable `:starter` (orchestrator resume turns) AND a
  fake `:tools` entrypoint that records `command_agent`/`delete_agent` calls instead of
  spawning real sessions. Real worker rows back the occupancy/`winding_down` lookups.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Agents
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrators

  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{System.unique_integer([:positive])}"}
    end
  end

  defp fake_tools(test_pid) do
    fn tool, _orchestrator_id, args ->
      send(test_pid, {:tool_call, tool, args})
      {:ok, %{"status" => "ok"}}
    end
  end

  defp enable_auto_resume do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )
  end

  defp start_queue(orchestrator_id) do
    start_supervised!(
      {Queue,
       orchestrator_id: orchestrator_id,
       starter: controllable_starter(self()),
       tools: fake_tools(self())}
    )
  end

  defp create_worker(orchestrator_id, attrs \\ %{}) do
    base = %{
      "name" => "w-#{System.unique_integer([:positive])}",
      "harness" => "claude",
      "provider" => "anthropic",
      "model" => "claude-opus-4-8",
      "session_id" => "sess-#{System.unique_integer([:positive])}"
    }

    {:ok, worker} = Agents.create_worker(orchestrator_id, Map.merge(base, attrs))
    worker
  end

  setup do
    enable_auto_resume()
    {:ok, orch} = Orchestrators.get_or_create_default()
    pid = start_queue(orch.id)
    %{orch: orch, pid: pid}
  end

  test "high occupancy + no signal issues exactly one wind-down and no resume", %{
    orch: orch,
    pid: pid
  } do
    worker = create_worker(orch.id)

    # 850k / 1M (Opus 4.8) = 0.85 ≥ 0.8 threshold → wind down.
    send(
      pid,
      {:worker_terminal,
       %{
         worker_id: worker.id,
         name: worker.name,
         ok?: true,
         context_tokens: 850_000,
         final_text: "still working, lots more to do"
       }}
    )

    assert_receive {:tool_call, "command_agent", %{"name" => name, "prompt" => prompt}}, 1_000
    assert name == worker.name
    assert prompt =~ "WIND DOWN"

    # No orchestrator resume for the wind-down terminal.
    refute_receive {:turn_started, _prompt, _}, 200

    # The worker is flagged winding_down.
    assert Agents.get_agent(worker.id).config["winding_down"] == true
  end

  test "a follow-up :handover terminal deletes the worker and resumes with the doc", %{
    orch: orch,
    pid: pid
  } do
    worker = create_worker(orch.id, %{"config" => %{"winding_down" => true}})

    send(
      pid,
      {:worker_terminal,
       %{
         worker_id: worker.id,
         name: worker.name,
         ok?: true,
         context_tokens: 900_000,
         final_text: "handed over.\n:handover ai_docs/w-handover.md"
       }}
    )

    assert_receive {:tool_call, "delete_agent", %{"name" => name}}, 1_000
    assert name == worker.name

    assert_receive {:turn_started, prompt, _resume}, 1_000
    assert prompt =~ "ai_docs/w-handover.md"
    assert prompt =~ "RETIRED"
  end

  test "already winding down, returned without a signal → force-retire", %{orch: orch, pid: pid} do
    worker = create_worker(orch.id, %{"config" => %{"winding_down" => true}})

    send(
      pid,
      {:worker_terminal,
       %{
         worker_id: worker.id,
         name: worker.name,
         ok?: true,
         context_tokens: 900_000,
         final_text: "ok I think I'm done but wrote no doc"
       }}
    )

    assert_receive {:tool_call, "delete_agent", %{"name" => name}}, 1_000
    assert name == worker.name

    assert_receive {:turn_started, prompt, _resume}, 1_000
    assert prompt =~ "WITHOUT writing a handover document"
  end

  test "a handover terminal is acted on even when its worker_id is already in seen", %{
    orch: orch,
    pid: pid
  } do
    worker = create_worker(orch.id)

    # First, a NORMAL terminal (under threshold, no signal) while idle → resumes and adds
    # the worker to seen_worker_ids.
    send(
      pid,
      {:worker_terminal,
       %{worker_id: worker.id, name: worker.name, ok?: true, context_tokens: 1_000}}
    )

    assert_receive {:turn_started, _prompt, turn}, 1_000
    # Drain that turn so the queue is idle again.
    ref = Process.monitor(turn)
    send(turn, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn, _}, 1_000

    # Now a handover terminal for the SAME (already-seen) worker — must NOT be deduped away.
    send(
      pid,
      {:worker_terminal,
       %{
         worker_id: worker.id,
         name: worker.name,
         ok?: true,
         context_tokens: 1_000,
         final_text: ":handover ai_docs/w-handover.md"
       }}
    )

    assert_receive {:tool_call, "delete_agent", %{"name" => _}}, 1_000
    assert_receive {:turn_started, prompt, _}, 1_000
    assert prompt =~ "ai_docs/w-handover.md"
  end

  test "a duplicate NON-handover terminal is still dropped (no regression)", %{
    orch: orch,
    pid: pid
  } do
    worker = create_worker(orch.id)
    info = %{worker_id: worker.id, name: worker.name, ok?: true, context_tokens: 1_000}

    send(pid, {:worker_terminal, info})
    assert_receive {:turn_started, _prompt, turn}, 1_000
    ref = Process.monitor(turn)
    send(turn, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn, _}, 1_000

    # Duplicate (same worker, no signal) → dropped.
    send(pid, {:worker_terminal, info})
    refute_receive {:turn_started, _prompt, _}, 200
  end
end
