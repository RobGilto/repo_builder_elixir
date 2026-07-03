defmodule RepoBuilder.WorkflowEngine.CatalogTest do
  @moduledoc """
  Unit tests for the workflow-type catalog: enumeration, fetch, per-type step shapes,
  the unknown-type error, and the default type. Pure data — no DB.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.WorkflowEngine.Catalog

  test "types/0 lists the built-in workflow types" do
    slugs = Enum.map(Catalog.types(), & &1.slug)
    assert "plan_build" in slugs
    assert "plan_build_review" in slugs
    assert "plan_build_review_fix" in slugs
    assert "spec_implement_test_review" in slugs
    assert length(slugs) >= 4
  end

  test "spec_implement_test_review is a spec-driven phase shape with a fix branch" do
    assert {:ok, steps} = Catalog.steps("spec_implement_test_review", "fake")
    names = Enum.map(steps, & &1["name"])
    assert names == ["spec", "implement", "test", "review", "fix"]
    review = Enum.find(steps, &(&1["name"] == "review"))
    assert review["on_failure"] == "fix"
  end

  test "every type carries a slug, label, and description" do
    for type <- Catalog.types() do
      assert is_binary(type.slug) and type.slug != ""
      assert is_binary(type.label) and type.label != ""
      assert is_binary(type.description) and type.description != ""
    end
  end

  test "default_type/0 is plan_build_review_fix" do
    assert Catalog.default_type() == "plan_build_review_fix"
    assert {:ok, _} = Catalog.fetch(Catalog.default_type())
  end

  describe "fetch/1" do
    test "returns the type for a known slug" do
      assert {:ok, type} = Catalog.fetch("plan_build")
      assert type.slug == "plan_build"
    end

    test "unknown slug is {:error, :unknown_type}" do
      assert {:error, :unknown_type} = Catalog.fetch("nope")
    end
  end

  describe "steps/2" do
    test "plan_build is plan → build" do
      assert {:ok, steps} = Catalog.steps("plan_build", "fake")
      assert step_names(steps) == ["plan", "build"]
      assert Enum.all?(steps, &(&1["harness"] == "fake"))
    end

    test "plan_build_review adds review" do
      assert {:ok, steps} = Catalog.steps("plan_build_review", "fake")
      assert step_names(steps) == ["plan", "build", "review"]
    end

    test "plan_build_review_fix is the full branching shape" do
      assert {:ok, steps} = Catalog.steps("plan_build_review_fix", "fake")
      assert step_names(steps) == ["plan", "build", "review", "fix"]

      review = Enum.find(steps, &(&1["name"] == "review"))
      # review branches to fix on failure, else succeeds to done.
      assert review["on_failure"] == "fix"
      assert review["on_success"] == "done"
    end

    test "the harness is threaded into every step" do
      assert {:ok, steps} = Catalog.steps("plan_build_review_fix", "claude")
      assert Enum.all?(steps, &(&1["harness"] == "claude"))
    end

    test "unknown type is {:error, :unknown_type}" do
      assert {:error, :unknown_type} = Catalog.steps("nope", "fake")
    end

    test "with_merge_step/1 rewires done edges to a terminal merge step (worktree runs)" do
      assert {:ok, steps} = Catalog.steps("plan_build_review_fix", "fake")
      merged = Catalog.with_merge_step(steps)

      merge = List.last(merged)
      assert %{"name" => "merge", "kind" => "merge", "on_success" => "done"} = merge

      # Every former success-terminal now routes through merge; failure edges untouched.
      for step <- merged, step["name"] != "merge" do
        refute step["on_success"] == "done"
      end

      assert Enum.find(merged, &(&1["name"] == "review"))["on_failure"] == "fix"

      # Idempotent — applying twice adds nothing.
      assert Catalog.with_merge_step(merged) == merged
    end
  end

  defp step_names(steps), do: Enum.map(steps, & &1["name"])
end
