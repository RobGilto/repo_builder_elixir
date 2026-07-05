defmodule RepoBuilder.Orchestrator.ServerTest do
  @moduledoc """
  The orchestrator turn drives the canned Fake orchestrator end-to-end (issue-c):
  the scripted `create_agent` → `command_agent` tool calls are dispatched in-process
  to `Orchestrator.Tools`, producing a worker row, a dispatched worker session, and
  the expected `console:events` broadcasts — all key-free.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Dashboard, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Server

  defp uniq, do: System.unique_integer([:positive])

  # Wait for all spawned (orchestrator + worker) sessions to finish before the
  # sandbox owner exits, so they neither crash on a torn-down connection nor leak
  # events into a later test's `console:events` subscription.
  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  test "a Fake orchestrator turn creates and commands a worker, streaming to console:events" do
    :ok = Dashboard.subscribe_events()

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

    assert {:ok, agent_id} = Server.run_turn(orch.id, "build me a thing")
    assert is_binary(agent_id)

    # Orchestrator text streams onto the global console feed.
    assert_receive {:agent_event, ^agent_id, %Event.TextDelta{}, _log_no}, 5_000

    # The in-process tool dispatch creates a worker and announces it on the feed.
    assert_receive {:agent_created, worker}, 5_000
    assert worker.orchestrator_id == orch.id

    # The worker row is durably persisted and scoped to this orchestrator.
    assert [persisted] = Agents.list_for_orchestrator(orch.id)
    assert persisted.name == worker.name

    # command_agent dispatched a session for the worker — its events also reach the
    # global feed under the worker's id (a different agent id than the orchestrator).
    assert_receive {:agent_event, worker_event_id, %Event.SessionStarted{}, _log_no}
                   when worker_event_id != agent_id,
                   5_000
  end

  test "captures the resumable session id and settles status to idle" do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

    assert {:ok, _agent_id} = Server.run_turn(orch.id, "hello")

    # Give the turn time to run the canned sequence to its Done frame.
    assert eventually(fn ->
             {:ok, reloaded} = Orchestrators.fetch(orch.id)
             reloaded.session_id == "fake-orchestrator" and reloaded.status == :idle
           end)
  end

  test "an orchestrator on a non-orchestrating harness is rejected" do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "cursor"})
    assert {:error, :not_orchestrator_capable} = Server.run_turn(orch.id, "go")
  end

  test "a Fake orchestrator turn persists at least one agent_logs row under orchestrator_id" do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

    assert {:ok, _agent_id} = Server.run_turn(orch.id, "persist me")

    # The orchestrator session carries orchestrator_db_id, so its canonical events
    # persist to agent_logs keyed by orchestrator_id (observability parity).
    assert eventually(fn ->
             Logs.list_recent_global(500)
             |> Enum.any?(&(&1.orchestrator_id == orch.id))
           end)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end

  describe "transient provider error threading (issue rate-limit-stall)" do
    alias RepoBuilder.Orchestrator.Ledgers
    alias RepoBuilder.Orchestrator.Server.State

    # A minimal turn State bound to `orch`, with the turn clock set so the auto-record
    # backstop is live (a nil `turn_started_at` no-ops it).
    defp turn_state(orch) do
      %State{
        orchestrator_id: orch.id,
        agent_id: "orch-#{uniq()}",
        prompt: "p",
        harness: "claude",
        in_process?: false,
        turn_started_at: DateTime.utc_now()
      }
    end

    test "a rate_limit Status then a not-ok Done auto-records a transient entry" do
      {:ok, orch} =
        Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      # The transient Status flags the turn...
      assert {:noreply, %State{transient_error?: true} = flagged} =
               Server.handle_info(
                 {:harness_event, %Event.Status{harness: :claude, kind: :rate_limit}},
                 turn_state(orch)
               )

      # ...so the not-ok terminal records :transient, not :error.
      assert {:stop, :normal, _} =
               Server.handle_info(
                 {:harness_event, %Event.Done{harness: :claude, ok: false, reason: :success}},
                 flagged
               )

      latest = Ledgers.latest_progress(orch.id)
      assert latest.transient == true
    end

    test "a not-ok Done WITHOUT a prior rate_limit records a plain (non-transient) error" do
      {:ok, orch} =
        Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

      {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

      assert {:stop, :normal, _} =
               Server.handle_info(
                 {:harness_event, %Event.Done{harness: :claude, ok: false, reason: :success}},
                 turn_state(orch)
               )

      latest = Ledgers.latest_progress(orch.id)
      assert latest.transient == false
    end
  end
end
