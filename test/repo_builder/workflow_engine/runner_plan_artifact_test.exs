defmodule RepoBuilder.WorkflowEngine.RunnerPlanArtifactTest do
  @moduledoc """
  Gap 4 regression tests: after a plan-family step (`plan` or `plan_f3`) completes,
  the Runner must extract the spec path from the planner's output and publish it as
  the `plan` artifact so downstream `{{plan}}` substitution resolves cleanly (not
  the full HTML body).

  Gap 1 (adw_new.py): plan_f3_block and feature_block now call build_plan correctly,
    synthesize the issue, set up the logger, and persist state.plan_file.
  Gap 2 (workflow_ops.py): plan_f3 and feature are now dispatched in run_local_workflow.
  Gap 3 (catalog.ex): plan_f3 has a dedicated default_prompt_template.
  Gap 4 (runner.ex): publish_plan_artifact post-step hook publishes plan artifact.

  This file covers Gap 4: the Elixir-side post-step hook in Runner, plus the salvage
  function that powers it.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{WorkflowEngine, Workflows}
  alias RepoBuilder.WorkflowEngine.Runner, as: Runner

  # ---------------------------------------------------------------------------
  # extract_spec_path — pure salvage function tested via apply/3 (private API)
  # ---------------------------------------------------------------------------

  describe "extract_spec_path/1 — pure salvage function" do
    test "extracts a bare specs/...html path" do
      assert {:ok, "specs/issue-42-adw-abc123-sdlc_planner-foo.html"} =
               Runner.extract_spec_path("specs/issue-42-adw-abc123-sdlc_planner-foo.html")
    end

    test "extracts from a code-fenced block" do
      output = """
      I've created the plan:

      ```html
      specs/issue-42-adw-abc123-sdlc_planner-foo.html
      ```
      """

      assert {:ok, "specs/issue-42-adw-abc123-sdlc_planner-foo.html"} =
               Runner.extract_spec_path(output)
    end

    test "extracts a .md spec path" do
      assert {:ok, "specs/issue-42-adw-abc123-sdlc_planner-bar.md"} =
               Runner.extract_spec_path("specs/issue-42-adw-abc123-sdlc_planner-bar.md")
    end

    test "extracts from chatty output (leading/trailing prose)" do
      output = """
      Planning complete.

      specs/issue-99-adw-def456-sdlc_planner-my-feature.html

      The plan covers all requirements.
      """

      assert {:ok, "specs/issue-99-adw-def456-sdlc_planner-my-feature.html"} =
               Runner.extract_spec_path(output)
    end

    test "returns :error when no specs/ path is present" do
      assert :error = Runner.extract_spec_path("Hello world, no spec here")
    end

    test "returns :error for empty string" do
      assert :error = Runner.extract_spec_path("")
    end

    test "returns :error when only non-spec paths are mentioned" do
      assert :error = Runner.extract_spec_path("Check lib/my_module.ex and test/test.exs")
    end

    test "code fences with language tags are stripped before matching" do
      output = """
      ```markdown
      specs/issue-1-adw-a1b2c3-sdlc_planner-x.html
      ```
      """

      assert {:ok, "specs/issue-1-adw-a1b2c3-sdlc_planner-x.html"} =
               Runner.extract_spec_path(output)
    end

    test "takes the FIRST match when multiple specs/ paths are present" do
      output = """
      specs/issue-1-adw-first-sdlc_planner-x.html
      specs/issue-2-adw-second-sdlc_planner-y.html
      """

      assert {:ok, "specs/issue-1-adw-first-sdlc_planner-x.html"} =
               Runner.extract_spec_path(output)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: end-to-end plan artifact flow via a custom Fake harness
  # ---------------------------------------------------------------------------

  defmodule SpecPathHarness do
    @moduledoc """
    A Fake harness variant that simulates a planner returning a spec path as final_text.
    Used for the end-to-end plan artifact publication integration test.
    """
    alias RepoBuilder.Harness.Fake
    @behaviour RepoBuilder.Harness

    @impl true
    def command(_opts) do
      spec_path = "specs/issue-42-adw-test-plan-sdlc_planner-my-feature.html"

      frames = [
        %{
          "type" => "session_started",
          "session_id" => "fake-session",
          "model" => "fake-model",
          "tools" => []
        },
        %{"type" => "text_delta", "text" => "Planning complete.\n\n"},
        %{"type" => "text_delta", "text" => "#{spec_path}\n"},
        %{"type" => "usage", "input_tokens" => 10, "output_tokens" => 5, "cost_usd" => 0.0},
        %{
          "type" => "done",
          "ok" => true,
          "reason" => "success",
          "final_text" => "#{spec_path}"
        }
      ]

      lines = Enum.map(frames, &Jason.encode!/1)
      {"printf", ["%s\n" | lines], [], harness: :fake}
    end

    @impl true
    def normalize(raw, ctx), do: Fake.normalize(raw, ctx)
  end

  describe "end-to-end: plan step produces plan artifact in run record" do
    test "plan step: run.artifacts includes 'plan' after completion" do
      # Register our spec-path-producing harness under a fresh key.
      register_harness("spec_plan", SpecPathHarness)

      # Build a minimal plan → done workflow using the spec_plan harness.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "runner-plan-artifact-#{uniq()}",
          type: "plan",
          state: :active,
          steps: [
            %{
              "name" => "plan",
              "harness" => "spec_plan",
              "prompt_template" => "Plan for: {{input}}",
              "on_success" => "done",
              "on_failure" => "abort"
            }
          ]
        })

      {:ok, run_id, pid} =
        WorkflowEngine.start_workflow(wf, inputs: %{"input" => "do the thing"})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000

      run = Workflows.get_run(run_id)

      assert run.status == :succeeded
      assert is_map(run.artifacts)
      assert run.artifacts["plan"] == "specs/issue-42-adw-test-plan-sdlc_planner-my-feature.html"
    end

    test "plan_f3 step: run.artifacts includes 'plan' after completion" do
      register_harness("spec_plan_f3", SpecPathHarness)

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "runner-planf3-artifact-#{uniq()}",
          type: "plan_f3",
          state: :active,
          steps: [
            %{
              "name" => "plan_f3",
              "harness" => "spec_plan_f3",
              "prompt_template" => "Author an HTML planf3 for: {{input}}",
              "on_success" => "done",
              "on_failure" => "abort"
            }
          ]
        })

      {:ok, run_id, pid} =
        WorkflowEngine.start_workflow(wf, inputs: %{"input" => "build a feature"})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000

      run = Workflows.get_run(run_id)

      assert run.status == :succeeded
      assert run.artifacts["plan"] == "specs/issue-42-adw-test-plan-sdlc_planner-my-feature.html"
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end
