defmodule RepoBuilder.OrphanReaperTest do
  # async: false — spawns real OS processes and reaps by marker.
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.OrphanReaper
  alias RepoBuilder.OsPidLedger

  @node to_string(node())

  defp spawn_sleep(env_pairs) do
    sleep = String.to_charlist(System.find_executable("sleep"))
    env = Enum.map(env_pairs, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    {:ok, _pid, os_pid} = :exec.run([sleep, ~c"60"], [{:env, env}, :monitor])
    # Wait for execve to complete (cmdline reflects "sleep") so /proc/<pid>/environ
    # carries the child's env, not the exec-port's — otherwise owns_pid? races.
    assert wait_until(fn -> proc_cmdline(os_pid) =~ "sleep" end)
    os_pid
  end

  defp proc_cmdline(os_pid) do
    case File.read("/proc/#{os_pid}/cmdline") do
      {:ok, cmdline} -> cmdline
      {:error, _} -> ""
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> :timer.sleep(20) && do_wait(fun, deadline)
    end
  end

  defp insert_row(os_pid, marker) do
    {:ok, _} =
      OsPidLedger.insert(%{
        session_id: "sess",
        os_pid: os_pid,
        marker: marker,
        node: @node,
        started_at: DateTime.utc_now()
      })
  end

  test "owns_pid?/2 verifies the marker in /proc/<pid>/environ" do
    marker = "mk-#{System.unique_integer([:positive])}"
    owned = spawn_sleep([{"REPO_BUILDER_SESSION_MARKER", marker}])
    unowned = spawn_sleep([{"SOMETHING_ELSE", "x"}])

    assert OrphanReaper.owns_pid?(owned, marker)
    refute OrphanReaper.owns_pid?(unowned, marker)
    refute OrphanReaper.owns_pid?(2_147_483_646, marker)

    System.cmd("kill", ["-KILL", Integer.to_string(owned)])
    System.cmd("kill", ["-KILL", Integer.to_string(unowned)])
  end

  test "reaps a marker-verified orphan and deletes its ledger row" do
    marker = "mk-#{System.unique_integer([:positive])}"
    os_pid = spawn_sleep([{"REPO_BUILDER_SESSION_MARKER", marker}])
    insert_row(os_pid, marker)

    assert OrphanReaper.reap_node(@node) == 1

    # The OS child was SIGKILLed — erlexec's monitor delivers DOWN — and the row is gone.
    assert_receive {:DOWN, ^os_pid, :process, _, _}, 2_000
    assert OsPidLedger.list_for_node(@node) == []
  end

  test "leaves a recycled/unrelated pid untouched, only dropping the stale row" do
    claimed_marker = "claimed-#{System.unique_integer([:positive])}"
    # The live process does NOT carry the claimed marker (simulates a recycled pid).
    os_pid = spawn_sleep([{"REPO_BUILDER_SESSION_MARKER", "a-different-marker"}])
    insert_row(os_pid, claimed_marker)

    assert OrphanReaper.reap_node(@node) == 0

    # The unrelated process is NOT signalled, and the stale row is dropped.
    refute_receive {:DOWN, ^os_pid, :process, _, _}, 500
    assert OsPidLedger.list_for_node(@node) == []

    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
  end

  test "drops the stale row for a dead pid without signalling" do
    marker = "dead-#{System.unique_integer([:positive])}"
    os_pid = spawn_sleep([{"REPO_BUILDER_SESSION_MARKER", marker}])
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {:DOWN, ^os_pid, :process, _, _}, 2_000

    insert_row(os_pid, marker)
    assert OrphanReaper.reap_node(@node) == 0
    assert OsPidLedger.list_for_node(@node) == []
  end
end
