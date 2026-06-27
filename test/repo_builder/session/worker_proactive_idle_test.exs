defmodule RepoBuilder.Session.WorkerProactiveIdleTest do
  @moduledoc """
  Self-healing Phase 1: a live WORKER session that goes quiet on meaningful events is
  demoted `:running → :idle` while staying ALIVE + resumable — instead of wedging at
  `:running` until the `idle_ms` timer kills it to `:error`.

  Drives the quiescence timer DETERMINISTICALLY by sending the `:quiescence` message
  directly to the live `Session.Server` (rather than waiting on a real 90 s timer), then
  asserts on `Agents.get_agent/1` status + process liveness via `Registry.lookup`. A real
  long-lived child (`sleep`) keeps the session alive across the assertions; it is stopped
  on exit. `async: false`: shared sandbox + the live `SessionRegistry` + global Mox.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Logs.Writer
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock
  @registry RepoBuilder.SessionRegistry

  setup do
    register_harness("mock", @mock)
    # A long-lived child so the session stays alive while we drive the timer by hand. No
    # stdout ⇒ `normalize/2` is never called; only `command/1` needs a stub.
    stub(@mock, :command, fn _opts -> {"/bin/sleep", ["120"], [], %{}} end)
    :ok = Dashboard.subscribe_events()
    :ok
  end

  # Start a live worker session bound to a fresh agent row; returns {agent, agent_id, pid}.
  # Registers an on_exit that stops the still-alive session so teardown drains promptly.
  defp start_worker(opts \\ []) do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: "anthropic"
      })

    agent_id = "worker-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Supervisor.start_session(
        [agent_id: agent_id, agent_db_id: agent.id, harness: "mock", prompt: "do work"] ++ opts
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          _kind, _reason -> :ok
        end
      end
    end)

    {agent, agent_id, pid}
  end

  test "a quiescent worker is demoted to :idle while staying alive and resumable" do
    {agent, agent_id, pid} = start_worker()
    db_id = agent.id
    {:ok, _} = Agents.set_status(db_id, :running)

    # Drive the quiescence timer by hand (deterministic — no 90 s wait).
    send(pid, :quiescence)

    assert_receive {:agent_updated, %Agent{id: ^db_id, status: :idle}}, 2_000
    assert Agents.get_agent(db_id).status == :idle

    # Still ALIVE + registered — the leader can re-engage it with one command_agent.
    assert Process.alive?(pid)
    assert Registry.lookup(@registry, agent_id) != []
  end

  test "a blocking-command worker is NOT demoted on quiescence" do
    {agent, _agent_id, pid} = start_worker()
    db_id = agent.id
    {:ok, _} = Agents.set_status(db_id, :running)

    # Mark it blocking (e.g. a `phx.server` step) via a stderr frame, then drive quiescence.
    %{os_pid: os_pid} = :sys.get_state(pid)
    send(pid, {:stderr, os_pid, "running mix phx.server\n"})
    send(pid, :quiescence)

    refute_receive {:agent_updated, %Agent{id: ^db_id, status: :idle}}, 300
    assert Agents.get_agent(db_id).status == :running
    assert Process.alive?(pid)
  end

  test "the idle_ms hard-kill still errors a truly abandoned session" do
    # Tiny idle_ms, large quiescence_ms ⇒ the HARD timer fires first and kills the session.
    {agent, agent_id, _pid} =
      start_worker(idle_ms: 50, quiescence_ms: 60_000)

    {:ok, _} = Agents.set_status(agent.id, :running)
    subscribe(agent_id)

    assert_receive {:harness_event, %Event.Error{reason: :idle_timeout}}, 2_000

    :ok = Writer.drain()
    assert Agents.get_agent(agent.id).status == :error
  end
end
