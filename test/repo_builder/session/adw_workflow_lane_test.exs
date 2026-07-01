defmodule RepoBuilder.Session.AdwWorkflowLaneTest do
  @moduledoc """
  Proves the §6 session runtime emits a `kind: :workflow` swimlane lane for an ADW-harness
  session (issue-two, change A). The portable ADW is modelled as a worker Agent, so the
  runtime historically broadcast only a `kind: :agent` lane — invisible on the console's
  ADWs screen, which renders `kind: :workflow` cards. `Session.Server.lane/3` now also
  broadcasts `%{id: "workflow:<agent_id>", kind: :workflow, ...}` for `state.harness == :adw`
  sessions, giving the run a surface. A non-ADW (Fake) worker must NOT emit such a lane.

  A canned fixture (run via `bash`, no `uv`/Python) drives a real ADW session while the
  test is subscribed to the lanes topic. `async: false` so the session GenServer shares the
  test's sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp adw_fixture do
    """
    #!/usr/bin/env bash
    emit() { printf '%s\\n' "$1"; }
    emit '{"schema_version":1,"type":"session_started","adw_id":"x","model":"m"}'
    emit '{"schema_version":1,"type":"step_start","adw_id":"x","adw_step":"plan","index":1,"total":1}'
    emit '{"schema_version":1,"type":"step_end","adw_id":"x","adw_step":"plan","status":"succeeded"}'
    emit '{"schema_version":1,"type":"done","adw_id":"x","ok":true,"reason":"success","final_text":"done"}'
    """
  end

  defp dir_with_adw(slug) do
    dir = Path.join(System.tmp_dir!(), "rb-adw-lane-#{uniq()}")
    File.mkdir_p!(Path.join(dir, "adws/adw_workflows"))
    File.write!(Path.join(dir, "adws/adw_workflows/adw_#{slug}.py"), adw_fixture())
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp register_project(dir) do
    {:ok, project} =
      RepoBuilder.Projects.create_project(%{
        "name" => "adw-lane-proj-#{uniq()}",
        "root_path" => dir
      })

    project
  end

  test "an ADW-harness session broadcasts a kind: :workflow lane for its run" do
    slug = "planl"
    target = dir_with_adw(slug)
    register_project(target)
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})

    :ok = Dashboard.subscribe()

    assert {:ok, %{"run_id" => run_id, "mode" => "adw"}} =
             Tools.call("start_adw", orch.id, %{
               "input" => "build it",
               "harness" => "adw",
               "workflow_type" => slug,
               "working_dir" => target,
               "adw_runner" => "bash"
             })

    # A `kind: :workflow` lane keyed to the run id (== agent id) arrives, running then
    # succeeded — this is what lights up the ADWs card. `run_id == agent_id` so the card's
    # step squares fill from the already-streaming ADW worker events.
    workflow_id = "workflow:#{run_id}"

    assert_receive {:lane,
                    %{id: ^workflow_id, kind: :workflow, status: :running, harness: "adw"}},
                   5_000

    assert_receive {:lane, %{id: ^workflow_id, kind: :workflow, status: :succeeded}}, 5_000
  end

  test "a non-ADW (Fake) worker never broadcasts a kind: :workflow lane" do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})

    {:ok, worker} =
      RepoBuilder.Agents.create_worker(orch.id, %{
        "name" => "w-#{uniq()}",
        "harness" => "fake",
        "model" => "fake-main"
      })

    :ok = Dashboard.subscribe()

    assert {:ok, %{"status" => "dispatched"}} =
             Tools.call("command_agent", orch.id, %{"name" => worker.name, "prompt" => "hi"})

    # The agent lane still flows; no workflow lane is ever emitted for a non-ADW harness.
    assert_receive {:lane, %{id: "agent:" <> _, kind: :agent}}, 5_000
    refute_receive {:lane, %{kind: :workflow}}, 200
  end
end
