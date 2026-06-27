defmodule RepoBuilder.Orchestrator.WorkerStackContractTest do
  @moduledoc """
  The load-bearing fix (stack-layers subsystem): a worker spawned for a project that has
  composed a stack carries the **stack contract** in its persisted `agents.system_prompt`
  — contract first, then the task body, then the reporting clause. A project with no
  selected layers (or a platform orchestrator) yields exactly today's prompt.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Orchestrators, Projects, StackLayers}
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    dir = Path.join(System.tmp_dir!(), "rb-wsc-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, project} = Projects.create_project(%{"name" => "wsc-#{uniq()}", "root_path" => dir})
    project
  end

  defp spawn_worker(orch_id, prompt) do
    name = "w-#{uniq()}"
    args = %{"name" => name, "harness" => "fake"}
    args = if prompt, do: Map.put(args, "system_prompt", prompt), else: args
    assert {:ok, _} = Tools.call("create_agent", orch_id, args)
    {:ok, worker} = Agents.get_by_name_for_orchestrator(orch_id, name)
    worker
  end

  test "a worker for a stacked project carries the contract first in its system_prompt" do
    project = project_fixture()

    {:ok, backend} =
      StackLayers.create_layer(%{
        "layer_type" => "backend",
        "name" => "Phoenix-#{uniq()}",
        "language" => "elixir",
        "reasoning" => "typed contexts only"
      })

    StackLayers.select_layer(project.id, backend.id)
    {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)

    worker = spawn_worker(orch.id, "Implement the feature.")

    assert worker.system_prompt =~ "## Project stack — build ONLY within this stack"
    assert worker.system_prompt =~ "Backend: Phoenix"
    assert worker.system_prompt =~ "(elixir)"
    assert worker.system_prompt =~ "STOP and report back"

    # Order: contract → task body → reporting clause.
    contract_at = :binary.match(worker.system_prompt, "build ONLY within this stack") |> elem(0)
    body_at = :binary.match(worker.system_prompt, "Implement the feature.") |> elem(0)
    assert contract_at < body_at
  end

  test "a project with no selected layers yields no contract (just the body + reporting)" do
    project = project_fixture()
    {:ok, orch} = Orchestrators.get_or_create_for_project(project.id)

    worker = spawn_worker(orch.id, "Do the thing.")

    refute worker.system_prompt =~ "build ONLY within this stack"
    assert worker.system_prompt =~ "Do the thing."
  end

  test "a platform orchestrator (project_id: nil) spawns a worker with no contract" do
    {:ok, orch} = Orchestrators.get_or_create_default()
    worker = spawn_worker(orch.id, nil)

    assert worker.project_id == nil
    refute worker.system_prompt =~ "build ONLY within this stack"
  end
end
