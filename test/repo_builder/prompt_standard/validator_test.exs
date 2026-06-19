defmodule RepoBuilder.PromptStandard.ValidatorTest do
  @moduledoc """
  Ports of the Python validator H/S-check tests (test_prompt_builder.py): H1, H3, H4, H6,
  H7, H8, H9, and S1–S5. Behavioral parity with `prompt_builder/validator.py`.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.PromptStandard.Validator

  defp errors_for(result, prefix),
    do: Enum.filter(result.errors, &String.starts_with?(&1, prefix))

  defp warnings_for(result, prefix),
    do: Enum.filter(result.warnings, &String.starts_with?(&1, prefix))

  describe "H1 — frontmatter contract" do
    test "fails for a Population A prompt without frontmatter" do
      content = "# Purpose\nDo something useful.\n\n## Workflow\n\n1. Do it.\n2. Done.\n"
      result = Validator.validate(content, :a)

      refute result.passed
      assert errors_for(result, "H1") != []
    end

    test "fails for a Population B prompt that has frontmatter" do
      content =
        "---\ndescription: Should not be here\nargument-hint: none\n---\n" <>
          "# Runtime Prompt\n\n## Core Operating Principle\n\nAlways delegate.\n"

      result = Validator.validate(content, :b)

      refute result.passed
      assert errors_for(result, "H1") != []
    end

    test "fails for malformed YAML frontmatter (distinct from absent)" do
      content = "---\ndescription: [unclosed\n---\n# Purpose\nDo work.\n"
      result = Validator.validate(content, :a)

      assert errors_for(result, "H1") != []
    end
  end

  describe "H3 — one templating mechanism per file" do
    test "fails when a file mixes {slot} and {{TOKEN}}" do
      content =
        "# My Prompt\n\n## Core Operating Principle\n\nDo this {task} with {{SUBAGENT_MAP}}.\n"

      result = Validator.validate(content, :b)

      refute result.passed
      assert errors_for(result, "H3") != []
    end
  end

  describe "H4 — closed token registry" do
    test "fails for an unregistered {{TOKEN}}" do
      content = "# Runtime Prompt\n\n## Core Operating Principle\n\nUse {{CUSTOM_TOKEN}}.\n"
      result = Validator.validate(content, :b)

      refute result.passed
      assert errors_for(result, "H4") != []
    end

    test "passes for a registered {{TOKEN}}" do
      content =
        "# Runtime Prompt\n\n## Available Subagent Templates\n\n{{SUBAGENT_MAP}}\n"

      result = Validator.validate(content, :b)

      assert errors_for(result, "H4") == []
    end
  end

  describe "H6 — Path-2 (.format) render smoke-test" do
    test "passes a clean named-slot Population B prompt" do
      content = "# Summarizer\n\n## Core Operating Principle\n\nSummarize: {topic} — {detail}\n"
      result = Validator.validate(content, :b)

      assert errors_for(result, "H6") == []
      assert result.passed
    end

    test "fails a Path-2 prompt with a stray brace" do
      content = "# Summarizer\n\n## Core Operating Principle\n\nSummarize: {topic} } extra\n"
      result = Validator.validate(content, :b)

      refute result.passed
      assert errors_for(result, "H6") != []
    end
  end

  describe "H7 — population taxonomy (tightened, longest-prefix)" do
    test "Population A with a B-only heading fails" do
      content =
        "---\ndescription: leaked a runtime heading.\nargument-hint: <topic>\n---\n" <>
          "# Purpose\nDo the work.\n\n## Workflow\n\n1. a.\n2. b.\n\n## Your Tools\n\nB-only.\n"

      result = Validator.validate(content, :a)

      refute result.passed
      assert [msg | _] = errors_for(result, "H7")
      assert msg =~ "## Your Tools"
    end

    test "Population B with an A-only heading fails" do
      content =
        "# Runtime Agent\n\n## Core Operating Principle\n\nAlways delegate.\n\n" <>
          "## Workflow\n\n1. Do.\n2. Done.\n"

      result = Validator.validate(content, :b)

      refute result.passed
      assert [msg | _] = errors_for(result, "H7")
      assert msg =~ "## Workflow"
    end

    test "a clean Population A prompt (with shared ## Instructions) passes" do
      content =
        "---\ndescription: A clean factory command.\nargument-hint: <topic>\n---\n" <>
          "# Purpose\nDo the work.\n\n## Instructions\n\n- Follow the workflow.\n\n" <>
          "## Workflow\n\n1. Step one.\n2. Step two.\n\n## Report\n\n- **Result**: done.\n"

      result = Validator.validate(content, :a)

      assert errors_for(result, "H7") == []
      assert result.passed
    end

    test "shared headings + ## Workflow Pattern are legal in Population B" do
      content =
        "# Orchestrator Agent System Prompt\n\n## Core Operating Principle — ALWAYS DELEGATE.\n\n" <>
          "## Instructions\n\n- Delegate every task.\n\n## Variables\n\nLEVEL: 80%\n\n" <>
          "## Workflow Pattern\n\n1. Analyze.\n2. Plan.\n3. Dispatch.\n"

      result = Validator.validate(content, :b)

      assert errors_for(result, "H7") == []
      assert result.passed
    end
  end

  describe "H8 — no UTF-8 BOM" do
    test "fails when content begins with a BOM" do
      content = "﻿# Runtime Agent\n\n## Core Operating Principle\n\nDelegate.\n"
      result = Validator.validate(content, :b)

      assert errors_for(result, "H8") != []
    end
  end

  describe "H9 — no unresolved $ARGUMENTS in a rendered Population A prompt" do
    test "fails when rendered Population A still contains $ARGUMENTS" do
      content = "---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nDo it.\n"
      rendered = content <> "\nUse $ARGUMENTS here.\n"
      result = Validator.validate(content, :a, rendered)

      assert errors_for(result, "H9") != []
    end
  end

  describe "SOFT checks" do
    test "S1 warns on an empty/too-short # Purpose" do
      content =
        "---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nx\n\n## Workflow\n\n1. a.\n2. b.\n"

      result = Validator.validate(content, :a)

      assert warnings_for(result, "S1") != []
    end

    test "S2 warns when ## Instructions uses slots missing from ## Variables" do
      content =
        "---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nDo the work thoroughly.\n\n" <>
          "## Variables\n\nNOTHING declared here.\n\n## Instructions\n\nUse {undeclared}.\n\n" <>
          "## Workflow\n\n1. a.\n2. b.\n"

      result = Validator.validate(content, :a)

      assert warnings_for(result, "S2") != []
    end

    test "S3 warns on a workflow with fewer than 2 numbered steps" do
      content =
        "---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nDo the work thoroughly.\n\n" <>
          "## Workflow\n\n1. Only one step.\n\n## Report\n\n- **Result**: done well.\n"

      result = Validator.validate(content, :a)

      assert warnings_for(result, "S3") != []
    end

    test "S4 warns on a missing/empty ## Report" do
      content =
        "---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nDo the work thoroughly.\n\n" <>
          "## Workflow\n\n1. a.\n2. b.\n"

      result = Validator.validate(content, :a)

      assert warnings_for(result, "S4") != []
    end

    test "S5 warns on a TODO/FIXME marker" do
      content =
        "# My Agent\n\n## Core Operating Principle\n\nAlways delegate. TODO: add detail.\n"

      result = Validator.validate(content, :b)

      assert warnings_for(result, "S5") != []
    end
  end

  describe "population auto-detection" do
    test "frontmatter present → :a; absent → :b" do
      assert Validator.validate("---\ndescription: d\nargument-hint: <a>\n---\n# Purpose\nGo.\n").population ==
               :a

      assert Validator.validate("# A\n\n## Core Operating Principle\n\nGo.\n").population == :b
    end
  end

  test "never raises on adversarial input" do
    assert %{} = Validator.validate("", :a)
    assert %{} = Validator.validate(<<0, 1, 2, 255>>, :b)
    assert %{} = Validator.validate(String.duplicate("{", 10_000), :b)
  end
end
