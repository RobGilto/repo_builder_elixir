defmodule RepoBuilder.PromptStandard.TaxonomyTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.PromptStandard.Taxonomy

  describe "classify_heading/1 longest-prefix classification" do
    test "Population-A-only heading classifies as :a" do
      assert Taxonomy.classify_heading("## Workflow") == :a
    end

    test "Population-B-only heading classifies as :b" do
      assert Taxonomy.classify_heading("## Workflow Pattern") == :b
      assert Taxonomy.classify_heading("## Your Tools") == :b
    end

    test "shared heading classifies as :shared and never fails a population" do
      assert Taxonomy.classify_heading("## Instructions") == :shared
      assert Taxonomy.classify_heading("## Variables") == :shared
    end

    test "a suffixed heading still classifies by its longest matching prefix" do
      assert Taxonomy.classify_heading("## Core Operating Principle — ALWAYS DELEGATE") == :b
    end

    test "longest-prefix keeps A's ## Workflow distinct from B's ## Workflow Pattern" do
      assert Taxonomy.classify_heading("## Workflow") == :a
      assert Taxonomy.classify_heading("## Workflow Pattern") == :b
    end

    test "an unknown heading classifies as nil" do
      assert Taxonomy.classify_heading("## Unknown Section") == nil
    end
  end
end
