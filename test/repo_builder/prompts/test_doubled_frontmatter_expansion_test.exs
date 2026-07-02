defmodule RepoBuilder.Prompts.TestDoubledFrontmatterExpansionTest do
  @moduledoc """
  Regression test for issue-log-40568: a command file wrapped with a pack-manifest
  frontmatter whose original Claude frontmatter was never removed carries TWO stacked
  `---`-fenced blocks. Before the fix, `SlashExpander` shipped the residual second
  frontmatter at the top of the expanded body; for the `pi` harness (no native slash
  handling) the leading `---` reached pi's CLI as an unknown option and killed the
  session (`provider exited: {:exit_status, 256}`, `Error: Unknown option: ---`).

  A slash-command body must therefore NEVER begin with a raw `---` frontmatter fence.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Prompts.SlashExpander

  @moduletag :tmp_dir

  # First non-blank line of an expanded body.
  defp first_content_line(expanded) do
    expanded
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  test "a doubled-frontmatter command expands without a residual fence", %{tmp_dir: tmp} do
    path = Path.join([tmp, ".claude", "commands", "build.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
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

    PATH_TO_PLAN: $ARGUMENTS
    """)

    expanded = SlashExpander.expand("/build specs/some plan.md", tmp)

    refute String.starts_with?(String.trim_leading(expanded), "---")
    assert first_content_line(expanded) == "# Build"
    # $ARGUMENTS carries the full remainder (space-bearing) intact.
    assert String.contains?(expanded, "PATH_TO_PLAN: specs/some plan.md")
  end

  test "every shipped .claude/commands/*.md expands without a leading fence" do
    root = Path.join([File.cwd!(), ".claude", "commands"])

    root
    |> Path.join("*.md")
    |> Path.wildcard()
    |> tap(fn files -> assert files != [], "expected shipped command files under #{root}" end)
    |> Enum.each(fn file ->
      name = file |> Path.basename() |> Path.rootname()
      expanded = SlashExpander.expand("/#{name} X", ".")

      refute String.starts_with?(String.trim_leading(expanded), "---"),
             "expanded body of /#{name} must not begin with a `---` frontmatter fence"
    end)
  end
end
