defmodule RepoBuilder.MultiHarnessTest do
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, WorkflowEngine, Workflows}
  alias RepoBuilder.Harness.{Cursor, Fake, Registry}

  defp uniq, do: System.unique_integer([:positive])

  test "the SAME ADW runs under different harness strings — only the string changes" do
    # The registry is the single selection seam: point both harness strings at the
    # canned Fake adapter so the same ADW runs to completion under each.
    register_harness("claude", Fake)
    register_harness("pi", Fake)

    for harness <- ["claude", "pi"] do
      {:ok, workflow} =
        WorkflowEngine.create_example_workflow("adw-#{harness}-#{uniq()}", harness)

      {:ok, run_id, pid} = WorkflowEngine.start_workflow(workflow, inputs: %{"input" => "go"})
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000
      assert Workflows.get_run(run_id).status == :succeeded, "ADW failed under harness #{harness}"
    end
  end

  test "runtime harness selection is string-based via the registry (no hardcoded modules)" do
    assert Registry.fetch("claude") |> ok_module() == RepoBuilder.Harness.Claude
    assert Registry.fetch("pi") |> ok_module() == RepoBuilder.Harness.Pi
    assert Registry.fetch("cursor") |> ok_module() == Cursor
  end

  test "adding a third harness (Cursor) is one module + one config entry — zero core edits" do
    # Resolves via the registry…
    assert Registry.fetch("cursor") == {:ok, Cursor}

    # …an agent referencing it passes validate_inclusion against the live registry…
    assert {:ok, agent} =
             Agents.create_agent(%{name: "cursor-#{uniq()}", harness: "cursor", provider: :local})

    assert agent.harness == "cursor"

    # …and a workflow step using "cursor" is accepted with NO edit to Event/Agent/runtime.
    assert {:ok, _wf} =
             Workflows.create_workflow(%{
               name: "cursor-wf-#{uniq()}",
               steps: [%{"name" => "x", "harness" => "cursor"}]
             })
  end

  defp ok_module({:ok, module}), do: module
end
