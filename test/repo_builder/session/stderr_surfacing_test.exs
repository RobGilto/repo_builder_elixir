defmodule RepoBuilder.Session.StderrSurfacingTest do
  @moduledoc """
  Regression guard (issue-fix-pi-orchestrator-extension-load): the session runtime
  used to DISCARD the child's stderr, so a provider that died with a diagnostic on
  stderr (e.g. pi's `Failed to load extension …`) surfaced only as a bare
  `provider exited`. The runtime must now fold a bounded stderr tail into the
  synthesized terminal `Event.Error`.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  defp unique_agent, do: "agent-" <> Integer.to_string(System.unique_integer([:positive]))

  setup do
    register_harness("mock", @mock)
    :ok
  end

  test "folds the child's stderr tail into the synthesized non-zero-exit Error" do
    agent = unique_agent()
    subscribe(agent)

    # Write a known diagnostic to STDERR (not stdout) and exit non-zero — the exact
    # shape of the pi extension-load failure this fix makes visible.
    stub(@mock, :command, fn _ ->
      {"sh", ["-c", ~s(echo "EXT_LOAD_FAILED: pi is not defined" 1>&2; exit 1)], [],
       %{harness: :mock}}
    end)

    stub(@mock, :normalize, fn _, _ -> :skip end)

    {:ok, pid} = Supervisor.start_session(agent_id: agent, harness: "mock", prompt: "x")
    ref = Process.monitor(pid)

    assert_receive {:harness_event, %Event.Error{message: message, reason: :provider_error}},
                   2_000

    assert message =~ "provider exited"
    assert message =~ "EXT_LOAD_FAILED: pi is not defined"

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end
end
