defmodule RepoBuilder.PromptStandard.FrontmatterTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.PromptStandard.Frontmatter

  @with_fm "---\ndescription: A command\nargument-hint: <topic>\n---\n# Purpose\nDo work.\n"
  @no_fm "# Runtime Agent\n\n## Core Operating Principle\n\nAlways delegate.\n"
  @malformed "---\ndescription: [unclosed\n---\n# Purpose\nDo work.\n"

  describe "present?/1" do
    test "true when a frontmatter fence opens the content" do
      assert Frontmatter.present?(@with_fm)
    end

    test "false when there is no fence (Population B)" do
      refute Frontmatter.present?(@no_fm)
    end
  end

  describe "parse/1" do
    test "returns {:ok, string-keyed map, body} for valid frontmatter" do
      assert {:ok, map, body} = Frontmatter.parse(@with_fm)
      assert map["description"] == "A command"
      assert map["argument-hint"] == "<topic>"
      assert body =~ "# Purpose"
    end

    test "returns :absent when there is no frontmatter" do
      assert Frontmatter.parse(@no_fm) == :absent
    end

    test "returns {:error, :malformed} for invalid YAML in the fence" do
      assert Frontmatter.parse(@malformed) == {:error, :malformed}
    end
  end

  describe "body/1" do
    test "returns the content after the closing fence" do
      assert Frontmatter.body(@with_fm) == "# Purpose\nDo work.\n"
    end

    test "returns the whole content when no fence is present" do
      assert Frontmatter.body(@no_fm) == @no_fm
    end

    test "extracts the body even when the YAML is malformed" do
      assert Frontmatter.body(@malformed) == "# Purpose\nDo work.\n"
    end
  end
end
