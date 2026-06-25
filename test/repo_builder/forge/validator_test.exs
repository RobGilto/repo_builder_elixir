defmodule RepoBuilder.Forge.ValidatorTest do
  @moduledoc "Per-kind structural gates (forge-meta-artifact-generation, Phase 3)."
  use ExUnit.Case, async: true

  alias RepoBuilder.Forge.Validator

  defp file(path, content), do: %{path: path, content: content}

  describe "command" do
    test "a well-formed command passes" do
      content = """
      ---
      description: Runs the project smoke test and reports the result.
      ---

      # Smoke Test

      ## Purpose

      Run the smoke test.

      ## Workflow

      1. Run it.

      ## Report

      Output the result.
      """

      assert :ok = Validator.validate(:command, [file("commands/smoke-test.md", content)])
    end

    test "missing sections and a non-kebab name fail" do
      content = """
      ---
      description: A thing.
      ---

      # Bad
      """

      assert {:error, reasons} =
               Validator.validate(:command, [file("commands/Bad_Name.md", content)])

      assert Enum.any?(reasons, &String.contains?(&1, "kebab"))
      assert Enum.any?(reasons, &String.contains?(&1, "Purpose"))
    end

    test "missing frontmatter fails" do
      assert {:error, [reason]} = Validator.validate(:command, [file("commands/x.md", "# No fm")])
      assert reason =~ "frontmatter"
    end

    test "no markdown artifact fails" do
      assert {:error, [reason]} = Validator.validate(:command, [file("notes.txt", "hi")])
      assert reason =~ "no .md"
    end
  end

  describe "skill" do
    test "a gerund-named skill with a short body passes" do
      content = """
      ---
      name: processing-invoices
      description: Processes invoices for the billing pipeline. Use when handling invoice files.
      ---

      # Processing Invoices

      ## Purpose

      Do the thing.
      """

      assert :ok =
               Validator.validate(:skill, [file("skills/processing-invoices/SKILL.md", content)])
    end

    test "a non-gerund name fails" do
      content = """
      ---
      name: invoice-helper
      description: Helps with invoices in the billing pipeline when needed.
      ---

      # x
      """

      assert {:error, reasons} =
               Validator.validate(:skill, [file("skills/invoice-helper/SKILL.md", content)])

      assert Enum.any?(reasons, &String.contains?(&1, "gerund"))
    end

    test "a body of 500+ lines fails" do
      body = Enum.map_join(1..520, "\n", &"line #{&1}")

      content = """
      ---
      name: doing-things
      description: Does things for the pipeline. Use when doing things is required here.
      ---

      #{body}
      """

      assert {:error, reasons} =
               Validator.validate(:skill, [file("skills/doing-things/SKILL.md", content)])

      assert Enum.any?(reasons, &String.contains?(&1, "500"))
    end
  end

  describe "workflow" do
    test "valid edges pass" do
      json =
        ~s({"slug":"plan-ship","steps":[{"name":"plan","on_success":"ship","on_failure":"abort"},{"name":"ship","on_success":"done","on_failure":"abort"}]})

      assert :ok = Validator.validate(:workflow, [file("workflows/plan-ship.json", json)])
    end

    test "a dangling edge fails" do
      json =
        ~s({"slug":"x","steps":[{"name":"plan","on_success":"nowhere","on_failure":"abort"}]})

      assert {:error, reasons} = Validator.validate(:workflow, [file("workflows/x.json", json)])
      assert Enum.any?(reasons, &String.contains?(&1, "dangling"))
    end

    test "invalid JSON fails" do
      assert {:error, [reason]} =
               Validator.validate(:workflow, [file("workflows/x.json", "{not json")])

      assert reason =~ "JSON"
    end
  end

  describe "agent" do
    test "a well-formed agent passes" do
      content = """
      ---
      name: code-reviewer
      description: Reviews changed code for correctness. Use when a diff needs review.
      tools: Read, Grep, Glob
      model: opus
      ---

      # Purpose

      Review code.

      ## Instructions

      - Be thorough.

      ## Workflow

      1. Read the diff.

      ## Report

      List findings.
      """

      assert :ok = Validator.validate(:agent, [file("agents/code-reviewer.md", content)])
    end

    test "missing tools fails" do
      content = """
      ---
      name: x
      description: Does something in the third person here for the team.
      ---

      # Purpose

      ## Instructions

      ## Workflow

      ## Report
      """

      assert {:error, reasons} = Validator.validate(:agent, [file("agents/x.md", content)])
      assert Enum.any?(reasons, &String.contains?(&1, "tools"))
    end
  end
end
