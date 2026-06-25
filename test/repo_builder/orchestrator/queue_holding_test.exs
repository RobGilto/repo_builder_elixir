defmodule RepoBuilder.Orchestrator.QueueHoldingTest do
  @moduledoc """
  Integration tests for the Queue's HOLDING branch (issue
  holding-status-for-blocked-agents): a worker that stopped blocked pending external input
  must SURVIVE (never reaped, never wound down) and, when auto-resume is enabled, owe
  exactly one holding-aware resume turn telling the orchestrator it is blocked (not done)
  and resumable via `command_agent`. Dedup and operator-supersede mirror the holding
  pattern.

  Drives the `Queue` with a controllable `:starter` (orchestrator resume turns) AND a fake
  `:tools` entrypoint that records `delete_agent`/`command_agent` calls instead of spawning
  real sessions — so "no reap" is asserted by the ABSENCE of a `delete_agent` tool call.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Queue

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

  defp start_queue do
    id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {Queue,
         orchestrator_id: id, starter: controllable_starter(self()), tools: fake_tools(self())}
      )

    {id, pid}
  end

  defp finish_turn(turn_pid) do
    ref = Process.monitor(turn_pid)
    send(turn_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn_pid, _}, 1_000
  end

  defp holding_info(attrs \\ %{}) do
    Map.merge(
      %{
        worker_id: Ecto.UUID.generate(),
        name: "scraper",
        ok?: true,
        holding?: true,
        holding_reason: "browser login required",
        final_text: "blocked\n:holding browser login required"
      },
      attrs
    )
  end

  test "a holding terminal does NOT reap the worker and enqueues one holding-aware resume" do
    enable_auto_resume()
    {_id, pid} = start_queue()

    # Queue is idle — the holding terminal fires the resume immediately.
    send(pid, {:worker_terminal, holding_info()})

    assert_receive {:turn_started, prompt, _turn}, 1_000
    # The resume names the worker as HOLDING (blocked), not done, and resumable.
    assert prompt =~ "scraper"
    assert prompt =~ "HOLDING"
    assert prompt =~ "browser login required"
    assert prompt =~ "command_agent"

    # No reap and no wind-down: the worker survives to be resumed.
    refute_receive {:tool_call, "delete_agent", _}, 200
    refute_receive {:tool_call, "command_agent", _}, 200
  end

  test "a duplicate holding signal for the same worker is suppressed" do
    enable_auto_resume()
    {_id, pid} = start_queue()

    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, holding_info(%{worker_id: worker_id})})
    assert_receive {:turn_started, _prompt, turn}, 1_000

    # Duplicate holding terminal for the same worker while the resume is in flight.
    send(pid, {:worker_terminal, holding_info(%{worker_id: worker_id})})
    finish_turn(turn)

    # No second resume — the duplicate was dropped.
    refute_receive {:turn_started, _prompt, _}, 200
    refute_receive {:tool_call, "delete_agent", _}, 200
  end

  test "an operator message supersedes a pending (mid-turn) holding resume" do
    enable_auto_resume()
    {id, pid} = start_queue()

    # An operator turn is in flight...
    assert {:ok, :started, _} = Queue.enqueue(id, "operator-1")
    assert_receive {:turn_started, "operator-1", turn1}, 1_000

    # ...a worker holds mid-turn (owes a resume)...
    send(pid, {:worker_terminal, holding_info()})
    # ...then the operator sends another message — it supersedes the owed resume.
    assert {:ok, :queued, 1} = Queue.enqueue(id, "operator-2")

    finish_turn(turn1)

    # The queued operator message runs next, NOT a holding resume.
    assert_receive {:turn_started, "operator-2", turn2}, 1_000
    finish_turn(turn2)
    refute_receive {:turn_started, _prompt, _}, 200
    refute_receive {:tool_call, "delete_agent", _}, 200
  end

  test "with auto-resume disabled, a holding terminal does NOT reap and enqueues nothing" do
    # config/test.exs ships auto_resume_on_worker_return: false (no enable here).
    {_id, pid} = start_queue()

    send(pid, {:worker_terminal, holding_info()})

    # Left holding for the operator: no resume turn, and crucially NO reap.
    refute_receive {:turn_started, _prompt, _}, 200
    refute_receive {:tool_call, "delete_agent", _}, 200
  end
end
