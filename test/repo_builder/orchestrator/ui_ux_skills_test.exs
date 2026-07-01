defmodule RepoBuilder.Orchestrator.UiUxSkillsTest do
  @moduledoc """
  The curated UI/UX knowledge assets (orchestrator-iterative-ui-ux-polish-phase, Phase 1):
  every shipped `SKILL.md` has valid frontmatter (Anthropic Agent Skills rules), the
  `ui-ux-mvp` orchestrator expertise renders, and the phased-delivery prompt teaches the
  UI/UX polish protocol.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Expertise
  alias RepoBuilder.Orchestrator.SystemPrompt

  @skills_dir Path.join([File.cwd!(), "plugin_library", "ui-ux-mvp", "skills"])
  @name_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  defp skill_files do
    Path.wildcard(Path.join(@skills_dir, "*/SKILL.md"))
  end

  defp frontmatter(path) do
    case String.split(File.read!(path), ~r/^---\s*$/m, parts: 3) do
      [leading, yaml, _body] ->
        assert String.trim(leading) == ""
        YamlElixir.read_from_string!(yaml)

      _other ->
        flunk("missing frontmatter in #{path}")
    end
  end

  describe "shipped SKILL.md bundles" do
    test "the four expected skills are present" do
      names = skill_files() |> Enum.map(&(&1 |> Path.dirname() |> Path.basename())) |> Enum.sort()

      assert names == ~w(desktop-ui-polish tui-ux-polish ui-ux-foundations web-ui-polish)
    end

    test "each has a valid name and a non-empty, bounded description" do
      for path <- skill_files() do
        fm = frontmatter(path)
        name = fm["name"]
        description = fm["description"]

        assert is_binary(name)
        assert Regex.match?(@name_regex, name), "bad skill name: #{inspect(name)}"
        assert String.length(name) <= 64
        refute name =~ "anthropic"
        refute name =~ "claude"

        assert is_binary(description)
        assert String.trim(description) != ""
        assert String.length(description) <= 1024
      end
    end
  end

  describe "ui-ux-mvp orchestrator expertise" do
    test "renders a non-empty mental model from the shipped seed" do
      body = Expertise.render("ui-ux-mvp")
      assert body =~ "UI/UX MVP"
      assert body =~ "iteration"
    end
  end

  describe "phased delivery prompt" do
    test "teaches the iterative UI/UX polish protocol" do
      block = SystemPrompt.phased_delivery_block()
      assert block =~ "ui_ux"
      assert block =~ "surfaces"
      assert block =~ "iteration cap"
    end
  end
end
