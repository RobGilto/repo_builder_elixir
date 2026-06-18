defmodule RepoBuilder.Orchestrator.StartAdwDiscoveryTest do
  @moduledoc """
  `start_adw` on the `adw` harness (issue-the-adw-gap): the requested `workflow_type`
  is validated against the DISCOVERED `adws/adw_*.py` set (app root + working-dir
  overlay), an unknown type lists the discovered slugs, and a valid launch spawns the
  real shell-out path through the ADW harness adapter + the §6 session runtime — its
  neutral stdout events persisting as canonical `agent_logs`, read back by `check_adw`.

  A canned-event fixture script (run via `bash`, no `uv`/Python needed) makes the spawn
  deterministic. `async: false` so the session GenServer sees the test's sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  # A neutral-event fixture: a bash script (named like an ADW so discovery finds it)
  # that ignores its args and prints the contract for a plan→build run, then done.
  @fixture """
  #!/usr/bin/env bash
  emit() { printf '%s\\n' "$1"; }
  emit '{"schema_version":1,"type":"session_started","adw_id":"x","model":"m"}'
  emit '{"schema_version":1,"type":"step_start","adw_id":"x","adw_step":"plan","index":1,"total":2}'
  emit '{"schema_version":1,"type":"text","adw_id":"x","adw_step":"plan","text":"planning"}'
  emit '{"schema_version":1,"type":"usage","adw_id":"x","adw_step":"plan","input_tokens":10,"output_tokens":5,"cost_usd":0.01}'
  emit '{"schema_version":1,"type":"step_end","adw_id":"x","adw_step":"plan","status":"succeeded","cost_usd":0.01}'
  emit '{"schema_version":1,"type":"step_start","adw_id":"x","adw_step":"build","index":2,"total":2}'
  emit '{"schema_version":1,"type":"step_end","adw_id":"x","adw_step":"build","status":"succeeded","cost_usd":0.02}'
  emit '{"schema_version":1,"type":"done","adw_id":"x","ok":true,"reason":"success","final_text":"shipped"}'
  """

  # Build a tmp working dir holding a discoverable fake ADW (`adw_<slug>.py`).
  defp working_dir_with_adw(slug) do
    dir = Path.join(System.tmp_dir!(), "rb-adw-#{uniq()}")
    File.mkdir_p!(Path.join(dir, "adws/adw_workflows"))
    File.write!(Path.join(dir, "adws/adw_workflows/adw_#{slug}.py"), @fixture)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp orchestrator_with_working_dir(dir) do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    {:ok, orch} = Orchestrators.set_working_dir(orch.id, dir)
    orch
  end

  defp wait_for_done(agent_id, attempts \\ 200) do
    events = RepoBuilder.Logs.list_recent(agent_id, 500)

    cond do
      Enum.any?(events, &(&1.event_type == :done)) -> :ok
      attempts > 0 -> Process.sleep(20) && wait_for_done(agent_id, attempts - 1)
      true -> flunk("ADW run #{agent_id} never persisted a terminal :done event")
    end
  end

  describe "validation against discovery" do
    test "an unknown workflow_type lists the discovered slugs (no crash)" do
      orch = orchestrator_with_working_dir(working_dir_with_adw("planbuildx"))

      assert {:error, reason} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "do it",
                 "harness" => "adw",
                 "workflow_type" => "nope"
               })

      assert reason =~ "unknown workflow_type nope"
      assert reason =~ "planbuildx"
    end

    test "a missing workflow_type for the adw harness is a clear error" do
      orch = orchestrator_with_working_dir(working_dir_with_adw("planbuildx"))

      assert {:error, reason} =
               Tools.call("start_adw", orch.id, %{"input" => "do it", "harness" => "adw"})

      assert reason =~ "workflow_type is required"
    end
  end

  describe "launch via the adapter" do
    test "spawns the discovered ADW and streams canonical events that check_adw reads" do
      slug = "planbuildx"
      orch = orchestrator_with_working_dir(working_dir_with_adw(slug))

      assert {:ok,
              %{
                "status" => "started",
                "run_id" => run_id,
                "workflow_type" => ^slug,
                "mode" => "adw"
              }} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "build the widget",
                 "harness" => "adw",
                 "workflow_type" => slug,
                 # Run the fixture through bash so no uv/Python is required in CI.
                 "adw_runner" => "bash"
               })

      wait_for_done(run_id)

      assert {:ok, summary} = Tools.call("check_adw", orch.id, %{"run_id" => run_id})
      assert summary["mode"] == "adw"
      assert summary["workflow_type"] == slug

      # Per-step status reconstructed from the canonical step markers.
      step_names = Enum.map(summary["steps"], & &1["name"])
      assert "plan" in step_names
      assert "build" in step_names
      assert Enum.all?(summary["steps"], &(&1["status"] == "succeeded"))
      assert summary["progress"]["total"] == 2

      # Cost rolled up from the canonical usage event(s).
      assert summary["cost_usd"] == "0.01"
    end
  end

  describe "check_adw unknown id" do
    test "an id matching neither a workflow run nor an agent is :not_found" do
      orch = orchestrator_with_working_dir(working_dir_with_adw("planbuildx"))

      assert {:error, :not_found} =
               Tools.call("check_adw", orch.id, %{"run_id" => Ecto.UUID.generate()})
    end
  end
end
