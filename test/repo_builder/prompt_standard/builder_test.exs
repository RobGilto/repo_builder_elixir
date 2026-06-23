defmodule RepoBuilder.PromptStandard.BuilderTest do
  @moduledoc """
  Ports of the Python builder tests (test_prompt_builder.py): Pop A/B assembly, render +
  injection invariant, unregistered-token rejection, level-7 Expertise ordering,
  build_and_validate ok/error, TOKEN_REGISTRY contents, and both-token render.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.PromptStandard
  alias RepoBuilder.PromptStandard.{Builder, PopAInput, PopBInput, TokenRegistry, Validator}

  describe "build_population_a/1" do
    test "produces YAML frontmatter and all required sections" do
      prompt =
        Builder.build_population_a(%PopAInput{
          name: "Test Prompt",
          purpose: "Run the test suite and report results.",
          description: "A test prompt for CI pipelines",
          argument_hint: "<path to test directory>",
          workflow: "1. Run tests.\n2. Report.",
          report: "- **Result**: pass or fail"
        })

      assert prompt =~ "---"
      assert prompt =~ "description:"
      assert prompt =~ "argument-hint:"
      assert prompt =~ "# Purpose"
      assert prompt =~ "## Workflow"
      assert prompt =~ "## Report"
      refute String.starts_with?(prompt, "﻿")
    end

    test "level >= 7 inserts ## Expertise before ## Workflow" do
      prompt =
        Builder.build_population_a(%PopAInput{
          name: "Self-Improving Builder",
          purpose: "Build and improve prompts via the L7 loop.",
          description: "A self-improving prompt builder",
          argument_hint: "<topic>",
          level: 7,
          expertise: "Accumulated domain know-how goes here.",
          workflow: "1. Gather learnings.\n2. Update Expertise.\n3. Verify."
        })

      expertise_pos = :binary.match(prompt, "## Expertise") |> elem(0)
      workflow_pos = :binary.match(prompt, "## Workflow") |> elem(0)
      assert expertise_pos < workflow_pos
    end
  end

  describe "build_population_b/1" do
    test "produces no frontmatter and the correct sections" do
      prompt =
        Builder.build_population_b(%PopBInput{
          name: "My Runtime Agent System Prompt",
          core_principle: "ALWAYS DELEGATE, NEVER DO THE WORK YOURSELF.",
          tools: "Use `list_agents` to enumerate agents.",
          routing_rules: "| Message shape | Action |\n|---|---|\n| task | delegate |"
        })

      refute String.starts_with?(prompt, "---")
      assert prompt =~ "# My Runtime Agent System Prompt"
      assert prompt =~ "## Core Operating Principle"
      assert prompt =~ "## Your Tools"
      assert prompt =~ "### Routing rules"
    end
  end

  describe "render/2" do
    test "replaces {{SUBAGENT_MAP}} and upholds the injection invariant" do
      template = "## Available Subagent Templates\n\n{{SUBAGENT_MAP}}\n"
      replacement = "- **coder**: Writes code\n- **reviewer**: Reviews code"

      assert {:ok, rendered} = Builder.render(template, %{"{{SUBAGENT_MAP}}" => replacement})
      assert rendered =~ replacement
      refute rendered =~ "{{"
      refute rendered =~ "}}"
    end

    test "rejects an unregistered token" do
      assert {:error, {:unregistered_tokens, ["{{UNKNOWN_TOKEN}}"]}} =
               Builder.render("Some {{UNKNOWN_TOKEN}} here.", %{"{{UNKNOWN_TOKEN}}" => "x"})
    end

    test "fails the injection invariant when a token is left unresolved" do
      assert {:error, :injection_invariant_violated} =
               Builder.render("{{SUBAGENT_MAP}} and {{HARNESS_CATALOG}}", %{
                 "{{SUBAGENT_MAP}}" => "agents"
               })
    end

    test "renders both registered tokens in one pass" do
      assert {:ok, rendered} =
               Builder.render("Agents: {{SUBAGENT_MAP}}\n\nHarness: {{HARNESS_CATALOG}}", %{
                 "{{SUBAGENT_MAP}}" => "- **coder**: writes code",
                 "{{HARNESS_CATALOG}}" => "pi/zai/main → glm-5.1\n⚠️ Orientation only"
               })

      refute rendered =~ "{{"
      refute rendered =~ "}}"
      assert rendered =~ "coder"
      assert rendered =~ "Orientation only"
    end
  end

  describe "build_and_validate/2" do
    test "returns {:ok, prompt, result} for a clean Population B prompt" do
      assert {:ok, prompt, result} =
               Builder.build_and_validate(:b, %PopBInput{
                 name: "Clean Agent",
                 core_principle: "Always delegate work to appropriate agents."
               })

      assert result.passed
      assert result.population == :b
      assert prompt =~ "# Clean Agent"
    end

    test "returns {:error, result} on a real HARD failure through the builder" do
      assert {:error, result} =
               Builder.build_and_validate(:b, %PopBInput{
                 name: "Broken Runtime Agent",
                 core_principle: "Delegate everything using {{BAD_TOKEN}} as the source of truth."
               })

      refute result.passed
      assert result.population == :b
      assert Enum.any?(result.errors, &String.starts_with?(&1, "H4"))
    end
  end

  describe "roundtrip — generated prompts validate clean" do
    test "Population A roundtrips to passed: true" do
      prompt =
        Builder.build_population_a(%PopAInput{
          name: "Deploy Service",
          purpose: "Deploy the specified service to the target environment.",
          description: "Deploy a service to the target environment",
          argument_hint: "<service-name> <environment>",
          instructions: "- IMPORTANT: if no SERVICE provided, stop and ask.",
          workflow: "1. Read the deploy config.\n2. Validate config.\n3. Run deploy script.",
          report: "- **Deployed**: SERVICE to ENVIRONMENT\n- **Status**: success / failed"
        })

      result = Validator.validate(prompt)
      assert result.passed, "Validation failed: #{inspect(result.errors)}"
      assert result.population == :a
    end

    test "Population B roundtrips to passed: true" do
      prompt =
        Builder.build_population_b(%PopBInput{
          name: "Code Review Agent System Prompt",
          core_principle: "Review all code changes thoroughly before approving.",
          tools: "Use `list_agents` to find reviewer agents.",
          routing_rules:
            "| Input | Action |\n|---|---|\n| PR diff | review |\n| question | answer |"
        })

      result = Validator.validate(prompt)
      assert result.passed, "Validation failed: #{inspect(result.errors)}"
      assert result.population == :b
    end
  end

  describe "TOKEN_REGISTRY" do
    test "contains the two v1 tokens plus the capability tokens (agentic-layer adaptor)" do
      registry = PromptStandard.token_registry()
      assert "{{SUBAGENT_MAP}}" in registry
      assert "{{HARNESS_CATALOG}}" in registry
      # Phase 3 extends the closed registry with capability tokens filled by the
      # command resolver from the active project's capability map.
      assert "{{TEST_COMMAND}}" in registry
      assert "{{SPEC_DIR}}" in registry

      assert length(registry) == 2 + length(TokenRegistry.capability_tokens())
    end
  end
end
