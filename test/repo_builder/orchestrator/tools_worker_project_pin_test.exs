defmodule RepoBuilder.Orchestrator.ToolsWorkerProjectPinTest do
  @moduledoc """
  Orchestrator↔project binding, Phase 4: spawned workers are PINNED to the commanding
  orchestrator's project, `command_agent` derives each worker's `cwd` from the worker's
  OWN project (drift-proof), and `start_adw` refuses an off-project `working_dir`.

  The cwd assertions use a tiny `pwd`-emitting harness adapter (a real subprocess that
  reports its working directory as a canonical `text_delta` event) — the same technique as
  `StartAdwWorkingDirTest`. `async: false` so the session GenServer sees the sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Logs, Orchestrators, Projects}
  alias RepoBuilder.Orchestrator.Tools

  # A real harness adapter whose process reports its `pwd` as a `text_delta`, so a test
  # can prove `command_agent` spawned the worker in the expected cwd. Normalization is the
  # Fake adapter's (the emitted frames are Fake-shaped JSONL).
  defmodule PwdHarness do
    @behaviour RepoBuilder.Harness

    @impl true
    def command(_opts) do
      script =
        ~s|printf '{"type":"session_started","session_id":"s","model":"m"}\\n'; | <>
          ~s|printf '{"type":"text_delta","text":"cwd=%s"}\\n' "$(pwd)"; | <>
          ~s|printf '{"type":"done","ok":true,"reason":"success","final_text":"done"}\\n'|

      {"bash", ["-c", script], [], %{harness: :fake}}
    end

    @impl true
    defdelegate normalize(raw, ctx), to: RepoBuilder.Harness.Fake
  end

  setup do
    register_harness("pwdfake", PwdHarness)
    on_exit(&drain_sessions/0)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "rb-pin-#{tag}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp project_at(dir) do
    {:ok, project} =
      Projects.create_project(%{"name" => "pin-proj-#{uniq()}", "root_path" => dir})

    project
  end

  defp wait_for_done(agent_id, attempts \\ 200) do
    if Enum.any?(Logs.list_recent(agent_id, 500), &(&1.event_type == :done)) do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        wait_for_done(agent_id, attempts - 1)
      else
        flunk("worker #{agent_id} never persisted a terminal :done event")
      end
    end
  end

  defp persisted_cwd(agent_id) do
    agent_id
    |> Logs.list_recent(500)
    |> Enum.find_value(fn
      %{event_type: :text_delta, payload: %{"text" => "cwd=" <> path}} -> String.trim(path)
      _ -> nil
    end)
  end

  describe "worker pinning (Phase 4.1)" do
    test "a worker spawned by a project-bound orchestrator inherits its project_id" do
      project = project_at(tmp_dir("a"))
      {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
      name = "w-#{uniq()}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.project_id == project.id
    end

    test "a platform orchestrator (project_id: nil) still spawns unscoped workers" do
      {:ok, orch} = Orchestrators.get_or_create_default()
      name = "w-#{uniq()}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.project_id == nil
    end
  end

  describe "dispatch cwd from the worker's own project (Phase 4.2)" do
    test "command_agent runs the worker in its project's root_path, drift-proof" do
      project_dir = tmp_dir("proj")
      drift_dir = tmp_dir("drift")
      project = project_at(project_dir)

      {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
      name = "w-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "pwdfake",
          "model" => "pwd-model"
        })

      # Drift the orchestrator's working_dir AFTER the worker is pinned: the worker must
      # still run in its OWN project, not wherever the orchestrator now points.
      {:ok, _} = Orchestrators.set_working_dir(orch.id, drift_dir)

      assert {:ok, %{"status" => "dispatched"}} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "go"})

      {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      wait_for_done(worker.id)
      cwd = persisted_cwd(worker.id)

      assert cwd, "fixture never reported its pwd"
      assert String.ends_with?(cwd, Path.basename(project_dir))
      refute String.ends_with?(cwd, Path.basename(drift_dir))
    end

    test "an unscoped worker falls back to the orchestrator's working dir (back-compat)" do
      orch_dir = tmp_dir("orchdir")
      {:ok, orch} = Orchestrators.get_or_create_default()
      {:ok, _} = Orchestrators.set_working_dir(orch.id, orch_dir)
      name = "w-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "pwdfake",
          "model" => "pwd-model"
        })

      {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.project_id == nil

      assert {:ok, %{"status" => "dispatched"}} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "go"})

      wait_for_done(worker.id)
      cwd = persisted_cwd(worker.id)
      assert cwd, "fixture never reported its pwd"
      assert String.ends_with?(cwd, Path.basename(orch_dir))
    end
  end

  describe "start_adw working_dir guard (Phase 4.3)" do
    test "an off-project working_dir is refused and spawns no worker" do
      project = project_at(tmp_dir("bound"))
      {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)
      before = length(Agents.list_for_orchestrator(orch.id))

      assert {:error, reason} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "build it",
                 "harness" => "adw",
                 "workflow_type" => "anything",
                 "working_dir" => "/tmp/not-a-registered-project-#{uniq()}"
               })

      assert reason =~ "is not the bound project / a registered project"
      assert length(Agents.list_for_orchestrator(orch.id)) == before
    end
  end
end
