defmodule RepoBuilder.Session.SupervisorTest do
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.Session.{Admission, Supervisor}

  @mock RepoBuilder.Harness.Mock

  defp unique_agent, do: "agent-" <> Integer.to_string(System.unique_integer([:positive]))

  test "killing one session is isolated: the other keeps running and the killed one is not restarted" do
    register_harness("mock", @mock)
    stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :mock}} end)
    stub(@mock, :normalize, fn _, _ -> :skip end)

    a1 = unique_agent()
    a2 = unique_agent()

    {:ok, p1} = Supervisor.start_session(agent_id: a1, harness: "mock", prompt: "x")
    {:ok, p2} = Supervisor.start_session(agent_id: a2, harness: "mock", prompt: "x")
    ref1 = Process.monitor(p1)

    # Wait until both have spawned their child (handle_continue done).
    assert is_integer(:sys.get_state(p1).os_pid)
    assert is_integer(:sys.get_state(p2).os_pid)

    Process.exit(p1, :kill)
    assert_receive {:DOWN, ^ref1, :process, _, :killed}, 2_000

    # The second session is unaffected and still registered.
    assert Process.alive?(p2)
    assert Supervisor.whereis(a2) == p2

    # The killed session is :temporary — not auto-restarted. Registry cleanup of the
    # dead pid is async, so whatever is (briefly) still registered for a1 must be the
    # DEAD original pid, never a freshly-restarted one.
    case Supervisor.whereis(a1) do
      nil -> :ok
      ^p1 -> refute Process.alive?(p1)
      other -> flunk("a1 was restarted as #{inspect(other)}")
    end

    # Cleanup: stop the survivor; compensate the admission slot the brutally-killed
    # session never released (terminate/2 does not run on :kill — that orphan is the
    # OrphanReaper's job in M3).
    :ok = Supervisor.stop_session(a2)
    Admission.release()
  end

  test "start_session reports {:error, :at_capacity} when the admission gate is full" do
    %{used: used, max: max} = Admission.count()
    to_fill = max - used

    for _ <- List.duplicate(:slot, to_fill), do: :ok = Admission.acquire()

    assert {:error, :at_capacity} =
             Supervisor.start_session(agent_id: unique_agent(), harness: "fake", prompt: "x")

    for _ <- List.duplicate(:slot, to_fill), do: Admission.release()
  end

  test "stop_session on an unknown agent returns {:error, :not_found}" do
    assert {:error, :not_found} = Supervisor.stop_session(unique_agent())
  end
end
