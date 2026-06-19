defmodule RepoBuilderWeb.TestOrchestratorHoldingPatternTest do
  @moduledoc """
  LiveView re-engagement proof for the holding pattern (issue holding-pattern-followup):
  when a worker the orchestrator dispatched returns WHILE the orchestrator's dispatch
  turn is still in flight, the console must not be left idle — once the turn drains the
  queue re-engages with exactly one auto-resume turn, and the console renders the
  orchestrator busy again rather than hung.

  A controllable `Queue` (pluggable `:starter`) is pre-started for the default
  orchestrator BEFORE mount so the busy/idle transitions are deterministic (no real
  harness timing). The worker-return wakeup is delivered through the real
  `Dashboard.broadcast_worker_terminal/2` seam the live worker session uses.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrators

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

  test "a worker returning mid-turn re-engages the console with an auto-resume turn", %{
    conn: conn,
    orch: orch
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # The orchestrator dispatches a worker and ends its turn — it is now busy.
    run_via_command(view, "dispatch a scout to gather info")
    assert_receive {:turn_started, "dispatch a scout to gather info", turn1}, 1_000
    assert wait_until(fn -> has_element?(view, "#orchestrator-queue", "Busy") end)

    # The worker returns WHILE the dispatch turn is still in flight (the bug's trigger).
    Dashboard.broadcast_worker_terminal(orch.id, %{worker_id: "w", name: "scout", ok?: true})
    # No second turn starts mid-flight; the resume is owed, not dropped.
    refute_receive {:turn_started, _prompt, _}, 200

    # The dispatch turn finishes. Pre-fix the console would go idle and hang here.
    ref = Process.monitor(turn1)
    send(turn1, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn1, _}, 1_000

    # Instead, the owed resume fires exactly once with an :auto_resume prompt naming the
    # returned worker, and the console shows the orchestrator busy again (re-engaged).
    assert_receive {:turn_started, prompt, _resume_turn}, 1_000
    assert prompt =~ "scout"
    assert prompt =~ "Review"

    assert wait_until(fn -> has_element?(view, "#orchestrator-queue", "Busy") end)
  end
end
