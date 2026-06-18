defmodule RepoBuilderWeb.TestOrchestratorQueueTest do
  @moduledoc """
  LiveView integration test for the orchestrator message queue (issue message-queue):
  while the orchestrator is busy, a second prompt renders a queued chip; canceling
  removes it; the queued message runs once the in-flight turn finishes.

  A controllable `Queue` (pluggable `:starter`) is pre-started for the default
  orchestrator BEFORE mount, so the console's `Queue.enqueue/2` routes through it and
  the busy/idle transitions are deterministic (no reliance on real harness timing).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrators

  # The controllable turn launcher: spawns a process the test holds and notifies the
  # test of each started prompt + pid, so a turn stays "in flight" until told to stop.
  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{System.unique_integer([:positive])}"}
    end
  end

  defp run_via_command(view, text) do
    view
    |> form("#command-form", command: text)
    |> render_submit()
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  setup do
    {:ok, orch} = Orchestrators.get_or_create_default()
    start_supervised!({Queue, orchestrator_id: orch.id, starter: controllable_starter(self())})
    %{orch: orch}
  end

  test "a second prompt while busy renders a queued chip; cancel removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # First prompt starts a turn (the orchestrator is now busy).
    run_via_command(view, "first task")
    assert_receive {:turn_started, "first task", _turn}, 1_000

    # Second prompt queues rather than starting a second turn.
    run_via_command(view, "second task")
    refute_receive {:turn_started, "second task", _}, 200

    assert wait_until(fn -> has_element?(view, "#orchestrator-queue") end)
    assert has_element?(view, "[id^=queued-]", "second task")
    assert has_element?(view, "#queue-badge", "1 queued")

    # Cancel the queued chip — it disappears and depth returns to zero (the strip
    # stays visible because the first turn is still in flight).
    view |> element("[id^=cancel-queued-]") |> render_click()
    refute has_element?(view, "[id^=cancel-queued-]")
    assert has_element?(view, "#queue-badge", "0 queued")
  end

  test "a queued message runs after the in-flight turn finishes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    run_via_command(view, "alpha")
    assert_receive {:turn_started, "alpha", turn1}, 1_000

    run_via_command(view, "beta")
    assert wait_until(fn -> has_element?(view, "#queue-badge", "1 queued") end)

    # Finish the in-flight turn: its monitor :DOWN dequeues and starts the queued one.
    ref = Process.monitor(turn1)
    send(turn1, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn1, _}, 1_000

    assert_receive {:turn_started, "beta", _turn2}, 1_000
    # The queue drains to depth 0 (still busy with "beta"); the strip clears its chip.
    assert wait_until(fn -> not has_element?(view, "#queue-badge", "1 queued") end)
  end
end
