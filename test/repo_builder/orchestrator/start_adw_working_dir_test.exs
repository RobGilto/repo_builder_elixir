defmodule RepoBuilder.Orchestrator.StartAdwWorkingDirTest do
  @moduledoc """
  `start_adw` on the `adw` harness threads a TARGET working directory into the worker's
  `opts.cwd` (issue-workflow-adw-step). This is the dominant fix: the worker (and thus
  the SDK's `.claude/commands/` resolution + the adapter's `--working-dir`) must run in
  the repo the ADW operates on, NOT the orchestrator's own dir.

  A canned-event fixture (run via `bash`, no `uv`/Python) emits its own `pwd`, so the
  test reads back the canonical `text` event to prove the spawned process ran in the
  resolved cwd. `async: false` so the session GenServer sees the test's sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  # A neutral-event fixture that emits its actual working directory (its `pwd`) as a
  # `text` event, so a test can confirm the process was spawned in `opts.cwd`.
  defp pwd_fixture do
    """
    #!/usr/bin/env bash
    emit() { printf '%s\\n' "$1"; }
    emit '{"schema_version":1,"type":"session_started","adw_id":"x","model":"m"}'
    emit '{"schema_version":1,"type":"step_start","adw_id":"x","adw_step":"plan","index":1,"total":1}'
    printf '{"schema_version":1,"type":"text","adw_id":"x","adw_step":"plan","text":"cwd=%s"}\\n' "$(pwd)"
    emit '{"schema_version":1,"type":"step_end","adw_id":"x","adw_step":"plan","status":"succeeded"}'
    emit '{"schema_version":1,"type":"done","adw_id":"x","ok":true,"reason":"success","final_text":"done"}'
    """
  end

  # A tmp dir holding a discoverable fake ADW (`adw_<slug>.py`) that emits its pwd.
  defp dir_with_adw(slug) do
    dir = Path.join(System.tmp_dir!(), "rb-adw-wd-#{uniq()}")
    File.mkdir_p!(Path.join(dir, "adws/adw_workflows"))
    File.write!(Path.join(dir, "adws/adw_workflows/adw_#{slug}.py"), pwd_fixture())
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp orchestrator(working_dir \\ nil) do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})

    case working_dir do
      nil -> orch
      dir -> elem(Orchestrators.set_working_dir(orch.id, dir), 1)
    end
  end

  defp wait_for_done(agent_id, attempts \\ 200) do
    if Enum.any?(Logs.list_recent(agent_id, 500), &(&1.event_type == :done)) do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        wait_for_done(agent_id, attempts - 1)
      else
        flunk("ADW run #{agent_id} never persisted a terminal :done event")
      end
    end
  end

  # The cwd the spawned fixture reported (from its `pwd` text event), or nil.
  defp persisted_cwd(agent_id) do
    agent_id
    |> Logs.list_recent(500)
    |> Enum.find_value(fn
      %{event_type: :text_delta, payload: %{"text" => "cwd=" <> path}} -> String.trim(path)
      _ -> nil
    end)
  end

  describe "explicit working_dir → that cwd" do
    test "the worker spawns in the explicit target dir, not the orchestrator's" do
      slug = "planx"
      target = dir_with_adw(slug)
      # Orchestrator has NO working dir of its own; the target is passed explicitly.
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id, "mode" => "adw"}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "build it",
                 "harness" => "adw",
                 "workflow_type" => slug,
                 "working_dir" => target,
                 "adw_runner" => "bash"
               })

      wait_for_done(run_id)
      cwd = persisted_cwd(run_id)
      assert cwd, "fixture never reported its pwd"
      assert String.ends_with?(cwd, Path.basename(target))
    end
  end

  describe "non-existent working_dir → error, no spawn" do
    test "a bad working_dir returns {:error, _} and creates no worker" do
      orch = orchestrator()
      before = length(RepoBuilder.Agents.list_for_orchestrator(orch.id))

      assert {:error, reason} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "build it",
                 "harness" => "adw",
                 "workflow_type" => "planx",
                 "working_dir" => "/no/such/dir-#{uniq()}"
               })

      assert reason =~ "is not an existing directory"
      # Validation precedes worker creation, so nothing was spawned.
      assert length(RepoBuilder.Agents.list_for_orchestrator(orch.id)) == before
    end
  end

  describe "omitted working_dir → orchestrator dir fallback (back-compat)" do
    test "the worker spawns in the orchestrator's working dir when none is passed" do
      slug = "plany"
      dir = dir_with_adw(slug)
      orch = orchestrator(dir)

      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "build it",
                 "harness" => "adw",
                 "workflow_type" => slug,
                 "adw_runner" => "bash"
               })

      wait_for_done(run_id)
      cwd = persisted_cwd(run_id)
      assert cwd, "fixture never reported its pwd"
      assert String.ends_with?(cwd, Path.basename(dir))
    end
  end
end
