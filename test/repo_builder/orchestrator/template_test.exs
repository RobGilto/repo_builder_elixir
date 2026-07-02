defmodule RepoBuilder.Orchestrator.TemplateTest do
  @moduledoc """
  Unit tests for the typed `Template` value: frontmatter parse/serialize round-trip
  and validation edge cases (missing name, non-kebab name, empty body, bad category,
  absent optional fields).
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.Template

  defp template(overrides \\ %{}) do
    base = %Template{
      name: "code-scout",
      description: "Reads code; never writes.",
      body: "You are a scout.",
      model: nil,
      category: "fast",
      harness: nil,
      version: 2,
      author: :operator,
      updated_at: ~U[2026-06-17 12:00:00Z]
    }

    struct(base, overrides)
  end

  describe "to_markdown/1 |> from_markdown/1" do
    test "round-trips the frontmatter and body" do
      markdown = Template.to_markdown(template())

      assert {:ok, attrs} = Template.from_markdown(markdown)
      assert attrs["name"] == "code-scout"
      assert attrs["description"] == "Reads code; never writes."
      assert attrs["body"] == "You are a scout."
      assert attrs["version"] == 2
      assert attrs["author"] == "operator"
      assert attrs["category"] == "fast"
    end

    test "omits absent optional fields and tolerates their absence on read" do
      markdown = Template.to_markdown(template(%{model: nil, category: nil, harness: nil}))

      refute markdown =~ "model:"
      refute markdown =~ "category:"
      refute markdown =~ "harness:"

      assert {:ok, attrs} = Template.from_markdown(markdown)
      assert attrs["model"] == nil
      assert :ok = Template.validate(attrs)
    end

    test "round-trips a description containing quotes and colons" do
      markdown = Template.to_markdown(template(%{description: ~s(Say: "be terse" always)}))

      assert {:ok, attrs} = Template.from_markdown(markdown)
      assert attrs["description"] == ~s(Say: "be terse" always)
    end
  end

  describe "from_markdown/1" do
    test "errors with no frontmatter" do
      assert {:error, _reason} = Template.from_markdown("just a body, no fences")
    end

    test "strips a second stacked frontmatter block from the body (issue-log-40568)" do
      markdown = """
      ---
      command: build
      version: 1.0.0
      ---

      ---
      description: Build the codebase based on the plan
      argument-hint: [path-to-plan]
      allowed-tools: Read, Write, Bash
      ---

      # Build

      Follow the workflow.
      """

      assert {:ok, attrs} = Template.from_markdown(markdown)
      # First block's keys are authoritative.
      assert attrs["command"] == "build"
      assert attrs["version"] == "1.0.0"
      # The embedded second frontmatter must not survive into the body.
      refute String.starts_with?(attrs["body"], "---")
      assert String.starts_with?(attrs["body"], "# Build")
      assert String.contains?(attrs["body"], "Follow the workflow.")
    end
  end

  describe "validate/1" do
    test "accepts a valid attrs map" do
      assert :ok =
               Template.validate(%{
                 "name" => "test-writer",
                 "description" => "d",
                 "body" => "b"
               })
    end

    test "rejects a missing name" do
      assert {:error, _} = Template.validate(%{"description" => "d", "body" => "b"})
    end

    test "rejects a non-kebab name" do
      assert {:error, :invalid_name} =
               Template.validate(%{"name" => "Code Scout", "description" => "d", "body" => "b"})
    end

    test "rejects an empty body" do
      assert {:error, _} =
               Template.validate(%{"name" => "x", "description" => "d", "body" => "   "})
    end

    test "rejects an unknown category" do
      assert {:error, :invalid_category} =
               Template.validate(%{
                 "name" => "x",
                 "description" => "d",
                 "body" => "b",
                 "category" => "wizard"
               })
    end

    test "accepts a known category" do
      assert :ok =
               Template.validate(%{
                 "name" => "x",
                 "description" => "d",
                 "body" => "b",
                 "category" => "heavy"
               })
    end
  end
end
