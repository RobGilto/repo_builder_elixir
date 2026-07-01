defmodule RepoBuilder.Prompts.TestSlashExpanderPlatformFallbackTest do
  @moduledoc """
  Regression test for the project-bound orchestrator chat: platform-only slash
  commands (`/bug`, `/chore`, `/feature`, …) that live solely in the app's own
  `.claude/commands/` — and are absent from the per-project command packs — must
  still expand when the expansion is project-aware, while project/pack resolution
  keeps winning on conflict. See
  `specs/issue-two-adw-issue-sdlc_planner-slash-commands-unavailable-in-project-bound-orchestrator-chat.md`.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project
  alias RepoBuilder.Prompts.SlashExpander

  @moduletag :tmp_dir

  # A foster project whose `root_path` ships no `.claude/commands/` — so its resolver
  # yields only pack commands, exactly like `worldWorkBench` from the bug report.
  defp project(root_path) do
    %Project{
      id: Ecto.UUID.generate(),
      name: "foster",
      root_path: root_path,
      stack: %{"language" => "node"},
      capabilities: %{"language" => "node"} |> Capabilities.detect() |> Capabilities.to_map(),
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }
  end

  defp write_command(dir, rel, body, frontmatter \\ "description: a test command") do
    path = Path.join([dir, ".claude", "commands", rel <> ".md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}\n")
    path
  end

  test "a platform-only command expands under a project-bound expansion", %{tmp_dir: tmp} do
    proj = project(tmp)

    # `/bug` lives ONLY in the app's `.claude/commands/bug.md`; the generic pack has no
    # `bug`, so before the overlay fix this passed through as the literal `/bug ...`.
    expanded = SlashExpander.expand("/bug something broke", tmp, proj)

    assert expanded =~ "# Bug Planning"
    refute expanded == "/bug something broke"
  end

  test "a repo-local command still overrides the platform default", %{tmp_dir: tmp} do
    write_command(tmp, "plan", "LOCAL PLAN for $ARGUMENTS")
    proj = project(tmp)

    # Repo-local `plan` wins over both the generic pack and the app-root `plan.md`,
    # proving the platform layer is overlaid UNDER project resolution, not over it.
    assert SlashExpander.expand("/plan the thing", tmp, proj) == "LOCAL PLAN for the thing"
  end

  test "an unknown command passes through verbatim under a project", %{tmp_dir: tmp} do
    proj = project(tmp)

    assert SlashExpander.expand("/definitely-not-a-command x", tmp, proj) ==
             "/definitely-not-a-command x"
  end
end
