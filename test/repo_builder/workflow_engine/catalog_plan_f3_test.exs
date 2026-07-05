defmodule RepoBuilder.WorkflowEngine.CatalogPlanF3Test do
  @moduledoc """
  Unit tests for the plan_f3 default_prompt_template clause (Gap 3 fix).
  Verifies the planf3-specific prompt includes the filename convention and output-contract
  phrase, and that every accepted step name has a template.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.WorkflowEngine.Catalog

  describe "default_prompt_template/1" do
    test "plan_f3 returns a non-empty template" do
      template = Catalog.default_prompt_template("plan_f3")
      assert template != ""
    end

    test "plan_f3 template references the planf3 filename convention" do
      template = Catalog.default_prompt_template("plan_f3")
      assert template =~ "specs/issue-"
      assert template =~ "adw-"
      assert template =~ "sdlc_planner-"
      # Must reference .html so the agent knows to author an HTML plan.
      assert template =~ ".html"
    end

    test "plan_f3 template includes the 'return ONLY the path' output contract" do
      template = Catalog.default_prompt_template("plan_f3")
      assert template =~ "Return ONLY"
      assert template =~ "path"
    end

    test "plan_f3 template differs from the generic fallback" do
      plan_f3_template = Catalog.default_prompt_template("plan_f3")
      fallback = Catalog.default_prompt_template("unknown_step_x")
      assert plan_f3_template !== fallback
      # plan_f3 is planf3-specific; fallback is generic.
      refute plan_f3_template =~ "Work on:"
    end

    test "every accepted step name returns a non-empty template" do
      step_names = ~w[plan patch build test review document ship plan_f3]

      for name <- step_names do
        template = Catalog.default_prompt_template(name)

        assert template != "",
               "step #{name} returned empty template"
      end
    end

    test "plan and plan_f3 templates differ (planf3 is HTML-first)" do
      plan_template = Catalog.default_prompt_template("plan")
      plan_f3_template = Catalog.default_prompt_template("plan_f3")
      assert plan_template !== plan_f3_template
      # plan_f3 is HTML; plan is markdown.
      assert plan_f3_template =~ ".html"
      refute plan_template =~ ".html"
    end

    test "build template uses {{plan}} (expects plan artifact handover)" do
      template = Catalog.default_prompt_template("build")
      assert template =~ "{{plan}}"
    end

    test "unknown step falls back to the generic input-driven template" do
      template = Catalog.default_prompt_template("my_custom_step")
      assert template =~ "{{input}}"
      assert template =~ "Spec (optional)"
    end
  end
end
