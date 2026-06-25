defmodule RepoBuilder.Session.WorkerStuckRunningTest do
  @moduledoc """
  Regression for issue-log-16249: a WORKER session whose spawn prelude fails before any
  `dispatch/2` must NOT leave `agents.status` stuck `:running`.

  Status reconciliation is entirely event-driven — `command_agent` flips the worker to
  `:running` optimistically the moment `start_session/1` returns `{:ok, pid}`, and only a
  canonical terminal event (routed through `Logs.Writer.update_status_quietly/2`) brings it
  back down. When the freshly-started `Session.Server` died inside `handle_continue(:spawn)`
  without emitting anything, no terminal ever came and the worker wedged `:running` forever.

  The deterministic seam is the session runtime + `agents.status` (the dashboard "still
  running" symptom is just a faithful render of that column). We drive a worker whose
  injected adapter `command/1` RAISES, then assert it settles on `:error` with a terminal
  `agent_logs` row. These assertions FAIL before the fix and PASS after.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Logs.Writer
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  defp unique_agent, do: "worker-" <> Integer.to_string(System.unique_integer([:positive]))

  setup do
    register_harness("mock", @mock)
    :ok
  end

  test "a worker whose spawn prelude raises ends at :error, not stuck :running" do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "skill-scaffolder-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: "anthropic"
      })

    agent_id = unique_agent()
    subscribe(agent_id)

    # The re-dispatched wind-down session's `adapter.command/1` raises in the spawn
    # prelude — exactly the silent-death class that wedged the worker `:running`.
    stub(@mock, :command, fn _ -> raise "boom: adapter.command crashed in spawn prelude" end)

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: agent_id,
        agent_db_id: agent.id,
        harness: "mock",
        prompt: "wind down"
      )

    ref = Process.monitor(pid)

    # Step 2: the loud-failure path surfaces a real terminal Error to the per-agent topic.
    assert_receive {:harness_event, %Event.Error{reason: :spawn_failed}}, 2_000
    # The worker session process is gone (it stopped, did not hang).
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # Await the async persistence so the terminal row + status reconciliation have landed.
    :ok = Writer.drain()

    # The defect: status stayed `:running`. The fix settles it on the terminal `:error`.
    assert Agents.get_agent(agent.id).status == :error

    # A terminal `agent_logs` row exists for the worker (today: none after the crash).
    logs = Logs.list_recent(agent.id)
    assert Enum.any?(logs, &(&1.event_type == :error))
  end
end
