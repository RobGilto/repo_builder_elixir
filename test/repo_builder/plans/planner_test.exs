defmodule RepoBuilder.Plans.PlannerTest do
  @moduledoc """
  The pure planner: deterministic step resolution (stack-correct, with provenance),
  estimate shape, intent classification, and unknown-type handling. Pure (in-memory
  `Project` struct), so async.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Plans.Planner
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project

  defp project(language) do
    %Project{
      id: Ecto.UUID.generate(),
      name: "p",
      root_path: nil,
      stack: %{"language" => language},
      capabilities: %{"language" => language} |> Capabilities.detect() |> Capabilities.to_map(),
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }
  end

  test "resolves stack-correct steps with provenance and a preview" do
    assert {:ok, preview} =
             Planner.resolve(%{
               project: project("elixir"),
               goal: "add a feature",
               workflow_type: "plan_build",
               harness: "fake"
             })

    assert Enum.map(preview.steps, & &1.name) == ["plan", "build"]
    build = Enum.find(preview.steps, &(&1.name == "build"))
    # build resolves from the elixir stack pack — preview shows the real body + provenance.
    assert build.provenance =~ "elixir@1.0.0"
    assert build.preview =~ "Elixir/Phoenix/OTP"
  end

  test "a node project previews stack-correct (npm) commands, not python/uv" do
    assert {:ok, preview} =
             Planner.resolve(%{
               project: project("node"),
               goal: "ship it",
               workflow_type: "plan_build",
               harness: "fake"
             })

    plan = Enum.find(preview.steps, &(&1.name == "plan"))
    assert plan.preview =~ "npm test"
    refute plan.preview =~ "uv run"
  end

  test "the estimate has context tokens, a window, a numeric cost, and a band" do
    {:ok, preview} =
      Planner.resolve(%{
        project: project("elixir"),
        goal: "x",
        workflow_type: "plan_build_review_fix",
        harness: "fake"
      })

    assert preview.estimate.context_tokens > 0
    assert preview.estimate.window > 0
    assert is_float(preview.estimate.estimated_cost_usd)
    assert preview.estimate.cost_band =~ "≈"
  end

  test "classifies intent from the goal" do
    assert Planner.classify_intent("fix the broken login") == "fix"
    assert Planner.classify_intent("bump dependencies") == "chore"
    assert Planner.classify_intent("add a dashboard") == "feat"
  end

  test "an unknown workflow type is {:error, :unknown_type}" do
    assert Planner.resolve(%{project: project("elixir"), goal: "g", workflow_type: "nope"}) ==
             {:error, :unknown_type}
  end
end
