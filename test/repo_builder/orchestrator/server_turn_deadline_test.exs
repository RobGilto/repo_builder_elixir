defmodule RepoBuilder.Orchestrator.ServerTurnDeadlineTest do
  @moduledoc """
  Self-healing Phase 4: the HARD per-turn deadline. A turn that stays byte-active (so the
  byte-idle `turn_idle_ms` watchdog never trips) but never finishes is force-flushed to
  `:error` and its harness session stopped, so the Driver can re-engage. Driven
  deterministically by sending `:turn_deadline` to the live `Server` (no real 180 s wait).

  Uses a Mock orchestrator harness whose session is a long `sleep` (byte-silent, stays alive).
  `async: false`: real sessions + the live `SessionRegistry` + global Mox.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrators

  @mock RepoBuilder.Harness.Mock
  @registry RepoBuilder.SessionRegistry

  setup do
    original = Application.fetch_env!(:repo_builder, :harnesses)

    entry = %{
      module: @mock,
      exe: "true",
      default_model: "m",
      price_table: %{},
      orchestrating: true
    }

    Application.put_env(:repo_builder, :harnesses, Map.put(original, "mock", entry))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)

    stub(@mock, :command, fn _opts -> {"/bin/sleep", ["120"], [], %{}} end)
    stub(@mock, :normalize, fn _raw, _ctx -> :skip end)
    :ok
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> :timeout
    end
  end

  test "a turn that hits the hard deadline is force-flushed to :error and its session stopped" do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "mock",
        model: "m"
      })

    {:ok, server_pid, agent_id} = Server.start_turn(orch.id, "do the long thing")
    ref = Process.monitor(server_pid)

    # The session must be live (registered) so the deadline has a session to stop.
    :ok = wait_until(fn -> Registry.lookup(@registry, agent_id) != [] end)

    send(server_pid, :turn_deadline)

    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    assert {:ok, %{status: :error}} = Orchestrators.fetch(orch.id)
    assert wait_until(fn -> Registry.lookup(@registry, agent_id) == [] end) == :ok
  end
end
