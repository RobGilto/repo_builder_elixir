defmodule RepoBuilder.Workflows.TitleHumanizerTest do
  @moduledoc """
  Unit tests for the Fast-tier ADW title humanizer (issue-unified-adw-swimlane-cards):
  the `machine_name?/1` detector, the persist-+-broadcast `apply_title/2`, and the
  `maybe_humanize_async/2` gating (with a stubbed runner so no model is hit).
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.{Dashboard, Orchestrators, Workflows}
  alias RepoBuilder.Workflows.TitleHumanizer

  # Stub runner: records the dispatch instead of starting a real Fast-tier session.
  defmodule RunnerStub do
    @moduledoc false
    @spec dispatch(RepoBuilder.Workflows.Workflow.t(), map()) :: :ok
    def dispatch(workflow, config) do
      send(
        Application.get_env(:repo_builder, :title_test_pid),
        {:dispatched, workflow.id, config}
      )

      :ok
    end
  end

  setup do
    Application.put_env(:repo_builder, TitleHumanizer, runner: {RunnerStub, :dispatch, 2})
    Application.put_env(:repo_builder, :title_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:repo_builder, TitleHumanizer)
      Application.delete_env(:repo_builder, :title_test_pid)
    end)

    :ok
  end

  defp workflow(attrs) do
    {:ok, wf} =
      Workflows.create_workflow(
        Map.merge(
          %{name: "wf-#{System.unique_integer([:positive])}", type: "plan_build", steps: []},
          attrs
        )
      )

    wf
  end

  defp orchestrator_with_fast do
    {:ok, orch} = Orchestrators.get_or_create_default("fake")

    {:ok, orch} =
      Orchestrators.set_agent_model(orch.id, "fast", %{
        "harness" => "fake",
        "model" => "fake-model-1"
      })

    orch
  end

  describe "machine_name?/1" do
    test "flags machine-looking names" do
      for name <- [
            nil,
            "",
            "232sdasdasd",
            "orch-adw-848273",
            "a1b2c3d4e5",
            "20260620",
            "550e8400-e29b-41d4-a716-446655440000"
          ] do
        assert TitleHumanizer.machine_name?(name), "expected #{inspect(name)} to be machine-like"
      end
    end

    test "leaves human-friendly names alone" do
      for name <- ["bug-fix-test", "Plan Build", "nightly release", "custom", "Refactor Auth"] do
        refute TitleHumanizer.machine_name?(name), "expected #{inspect(name)} to be human-like"
      end
    end
  end

  describe "apply_title/2" do
    test "sanitizes, persists metadata[\"title\"], and broadcasts" do
      wf = workflow(%{})
      :ok = Dashboard.subscribe()

      assert :ok = TitleHumanizer.apply_title(wf, ~s("Fix Login Bug"\n extra junk))

      assert_receive {:workflow_title, workflow_id, "Fix Login Bug"}
      assert workflow_id == wf.id
      assert Workflows.get_workflow(wf.id).metadata["title"] == "Fix Login Bug"
    end

    test "a blank reply is a no-op (heuristic title stands)" do
      wf = workflow(%{})
      assert :ok = TitleHumanizer.apply_title(wf, "   ")
      refute Map.has_key?(Workflows.get_workflow(wf.id).metadata, "title")
    end
  end

  describe "maybe_humanize_async/2" do
    test "dispatches the runner for a machine-looking name with a Fast tier" do
      orch = orchestrator_with_fast()
      wf = workflow(%{name: "orch-adw-848273"})

      assert :ok = TitleHumanizer.maybe_humanize_async(wf, orch.id)
      assert_receive {:dispatched, workflow_id, %{harness: "fake", model: "fake-model-1"}}
      assert workflow_id == wf.id
    end

    test "no-ops for a human-friendly name" do
      orch = orchestrator_with_fast()
      wf = workflow(%{name: "Refactor Auth"})

      assert :ok = TitleHumanizer.maybe_humanize_async(wf, orch.id)
      refute_receive {:dispatched, _, _}
    end

    test "no-ops when metadata[\"title\"] is already set (idempotent)" do
      orch = orchestrator_with_fast()
      {:ok, wf} = Workflows.put_workflow_title(workflow(%{name: "orch-adw-1"}), "Already Named")

      assert :ok = TitleHumanizer.maybe_humanize_async(wf, orch.id)
      refute_receive {:dispatched, _, _}
    end

    test "no-ops when the orchestrator has no Fast tier" do
      {:ok, orch} = Orchestrators.get_or_create_default("fake")
      wf = workflow(%{name: "orch-adw-848273"})

      assert :ok = TitleHumanizer.maybe_humanize_async(wf, orch.id)
      refute_receive {:dispatched, _, _}
    end

    test "no-ops when orchestrator_id is nil/unknown" do
      assert :ok = TitleHumanizer.maybe_humanize_async(workflow(%{name: "orch-adw-1"}), nil)

      assert :ok =
               TitleHumanizer.maybe_humanize_async(
                 workflow(%{name: "orch-adw-2"}),
                 Ecto.UUID.generate()
               )

      refute_receive {:dispatched, _, _}
    end
  end
end
