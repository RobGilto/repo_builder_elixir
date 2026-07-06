defmodule RepoBuilder.Forge.GeneratorsPresentTest do
  @moduledoc """
  Phase 1 asset contract (forge-meta-artifact-generation): no runtime code yet — assert
  the vendored generator templates exist, are well-formed (carry their required section
  markers + the `{{PROJECT_CONTEXT}}` render slot), and that the `:forge` config reads back.
  """
  use ExUnit.Case, async: true

  @generators_dir Application.compile_env!(:repo_builder, :forge)[:generators_dir]

  # Each template + the markers it MUST contain (the per-kind asset contract).
  @required %{
    "command.md" => [
      "{{PROJECT_CONTEXT}}",
      "{{SPEC}}",
      "{{TEST_COMMAND}}",
      "{{SPEC_DIR}}",
      "## Purpose",
      "## Workflow",
      "## Report"
    ],
    "agent.md" => [
      "{{PROJECT_CONTEXT}}",
      "{{SPEC}}",
      "# Purpose",
      "## Instructions",
      "## Workflow",
      "## Report"
    ],
    "skill.md" => ["{{PROJECT_CONTEXT}}", "{{SPEC}}", "gerund", "THIRD PERSON", "< 500 lines"],
    "workflow.md" => ["{{PROJECT_CONTEXT}}", "{{SPEC}}", "on_success", "on_failure", "slug"],
    "design_system.md" => [
      "{{PROJECT_CONTEXT}}",
      "{{SPEC}}",
      "surface",
      "framework",
      "paradigm",
      "components"
    ]
  }

  @spec dir() :: String.t()
  defp dir, do: Path.expand(@generators_dir, File.cwd!())

  test "all five generator templates exist with their required markers" do
    for {file, markers} <- @required do
      path = Path.join(dir(), file)
      assert File.exists?(path), "missing generator template: #{path}"
      {:ok, body} = File.read(path)

      for marker <- markers do
        assert String.contains?(body, marker),
               "#{file} is missing required marker: #{inspect(marker)}"
      end
    end
  end

  test "the :forge config block reads back" do
    forge = Application.fetch_env!(:repo_builder, :forge)
    assert is_binary(forge[:generators_dir])
    assert is_binary(forge[:generation_harness])
    assert is_binary(forge[:scratch_base])
    assert is_binary(forge[:default_source])
  end
end
