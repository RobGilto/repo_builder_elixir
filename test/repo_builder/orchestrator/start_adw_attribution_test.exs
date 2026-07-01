defmodule RepoBuilder.Orchestrator.StartAdwAttributionTest do
  @moduledoc """
  Regression guard for issue-two (the `de59371` divergence): the portable / shell-out ADW
  path (`start_adw_via_adapter/4` → `spawn_adw_session`) must thread the resolved bound
  `project_id` (plus `orchestrator_id`/`provider`/`isolation_mode` for worker-terminal +
  vault parity) into the session opts, exactly as `command_agent/3` does. Before the fix
  the adapter path passed none, so ADW `agent_logs` rows persisted with `project_id = NULL`
  — outside the launching project's scoped feed.

  A worker log row is keyed by `agent_id` (its `orchestrator_id` column is NULL by the
  exactly-one-owner constraint), so ownership by the orchestrator is asserted on the AGENT
  row and project scoping on the persisted log rows. This asserts via the SESSION's
  persisted output (not the private function): a canned fixture (run via `bash`, no
  `uv`/Python) drives a real ADW session. `async: false` so the session GenServer sees the
  test's sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Agents
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  # A neutral-event fixture emitting a minimal plan step + terminal :done.
  defp adw_fixture do
    """
    #!/usr/bin/env bash
    emit() { printf '%s\\n' "$1"; }
    emit '{"schema_version":1,"type":"session_started","adw_id":"x","model":"m"}'
    emit '{"schema_version":1,"type":"step_start","adw_id":"x","adw_step":"plan","index":1,"total":1}'
    emit '{"schema_version":1,"type":"text","adw_id":"x","adw_step":"plan","text":"planning"}'
    emit '{"schema_version":1,"type":"step_end","adw_id":"x","adw_step":"plan","status":"succeeded"}'
    emit '{"schema_version":1,"type":"done","adw_id":"x","ok":true,"reason":"success","final_text":"done"}'
    """
  end

  defp dir_with_adw(slug) do
    dir = Path.join(System.tmp_dir!(), "rb-adw-attr-#{uniq()}")
    File.mkdir_p!(Path.join(dir, "adws/adw_workflows"))
    File.write!(Path.join(dir, "adws/adw_workflows/adw_#{slug}.py"), adw_fixture())
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp register_project(dir) do
    {:ok, project} =
      RepoBuilder.Projects.create_project(%{
        "name" => "adw-attr-proj-#{uniq()}",
        "root_path" => dir
      })

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
        flunk("ADW run #{agent_id} never persisted a terminal :done event")
      end
    end
  end

  test "adapter ADW is owned by the orchestrator and its events are project-scoped" do
    slug = "plana"
    target = dir_with_adw(slug)
    project = register_project(target)
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})

    assert {:ok, %{"run_id" => run_id, "mode" => "adw"}} =
             Tools.call("start_adw", orch.id, %{
               "input" => "build it",
               "harness" => "adw",
               "workflow_type" => slug,
               "working_dir" => target,
               "adw_runner" => "bash"
             })

    wait_for_done(run_id)

    # Ownership: the worker/agent row (run_id == worker.id) is owned by the launching
    # orchestrator (create_worker sets it; the log rows are keyed by agent_id).
    worker = Agents.get_agent(run_id)
    assert worker.orchestrator_id == orch.id

    # Scoping (the regression fix): every persisted ADW log row carries the target
    # project_id — before the fix `spawn_adw_session` passed no project, so it was NULL and
    # the events fell outside the active project's scoped feed.
    rows = Logs.list_recent(run_id, 500)
    assert rows != []

    assert Enum.all?(rows, &(&1.project_id == project.id)),
           "expected all ADW rows scoped to the target project"
  end
end
