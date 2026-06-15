defmodule RepoBuilder.OrphanReaper do
  @moduledoc """
  Boot-time reconciliation of orphaned OS children via the durable os_pid ledger
  (BUILD_PROMPT.md §5/§6).

  After a hard BEAM crash, erlexec cannot reap the children it spawned (it only
  reaps on a clean emulator exit). On the next boot this reaper reads every
  `os_pid_ledger` row for this node and — crucially — verifies each live pid is
  ACTUALLY ours via `/proc/<os_pid>/environ` carrying
  `REPO_BUILDER_SESSION_MARKER=<marker>` BEFORE sending any signal. It never kills
  by bare pid (a pid may have been recycled by an unrelated process).

    * dead pid                → delete the stale row (no signal)
    * live + marker matches   → SIGTERM, then SIGKILL after a grace, delete the row
    * live + marker mismatch  → recycled/unrelated pid: delete the row, NEVER signal

  Started after `Repo`. Disabled on boot in tests (`reap_on_boot: false`); tests
  drive `reap_node/1` explicitly.
  """
  use GenServer

  require Logger

  alias RepoBuilder.OsPidLedger
  alias RepoBuilder.OsPidLedger.OsPid

  @sigterm_grace_ms 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if reap_on_boot?() do
      {:ok, opts, {:continue, :reap}}
    else
      {:ok, opts}
    end
  end

  @impl true
  def handle_continue(:reap, state) do
    _ = reap_node(to_string(node()))
    {:noreply, state}
  end

  @doc "Reconcile every ledger row recorded for `node_name`. Returns the count reaped (killed)."
  @spec reap_node(String.t()) :: non_neg_integer()
  def reap_node(node_name) do
    node_name
    |> OsPidLedger.list_for_node()
    |> Enum.reduce(0, fn row, killed -> killed + reap_row(row) end)
  end

  @doc "Reconcile one ledger row. Returns 1 if it killed a verified-owned pid, else 0."
  @spec reap_row(OsPid.t()) :: 0 | 1
  def reap_row(%OsPid{os_pid: os_pid, marker: marker}) do
    cond do
      not pid_alive?(os_pid) ->
        _ = OsPidLedger.delete_by_marker(marker)
        0

      owns_pid?(os_pid, marker) ->
        kill_pid(os_pid)
        _ = OsPidLedger.delete_by_marker(marker)
        Logger.info("OrphanReaper reaped marked orphan os_pid=#{os_pid}")
        1

      true ->
        # Recycled / unrelated pid — drop the stale row, NEVER signal it.
        _ = OsPidLedger.delete_by_marker(marker)
        0
    end
  end

  @doc "True iff the live process at `os_pid` carries our `REPO_BUILDER_SESSION_MARKER=<marker>`."
  @spec owns_pid?(non_neg_integer(), String.t()) :: boolean()
  def owns_pid?(os_pid, marker) do
    case File.read("/proc/#{os_pid}/environ") do
      {:ok, environ} -> String.contains?(environ, "REPO_BUILDER_SESSION_MARKER=#{marker}")
      {:error, _reason} -> false
    end
  end

  @spec pid_alive?(non_neg_integer()) :: boolean()
  defp pid_alive?(os_pid), do: File.dir?("/proc/#{os_pid}")

  @spec kill_pid(non_neg_integer()) :: :ok
  defp kill_pid(os_pid) do
    _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(@sigterm_grace_ms)

    _ =
      if pid_alive?(os_pid),
        do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    :ok
  end

  @spec reap_on_boot?() :: boolean()
  defp reap_on_boot? do
    :repo_builder
    |> Application.get_env(:orphan_reaper, [])
    |> Keyword.get(:reap_on_boot, true)
  end
end
