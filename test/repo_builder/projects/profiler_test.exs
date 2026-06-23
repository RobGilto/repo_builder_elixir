defmodule RepoBuilder.Projects.ProfilerTest do
  @moduledoc """
  Stack + convention detection across hermetic fixture repos generated in tmp, plus
  fail-silent behaviour on a missing directory. `async: false` is unnecessary — no
  shared state — so these run async.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Profiler

  setup do
    base = Path.join(System.tmp_dir!(), "rb_profiler_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp mkrepo(base, name, files) do
    root = Path.join(base, name)
    File.mkdir_p!(Path.join(root, ".claude/commands"))

    Enum.each(files, fn {path, contents} ->
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end)

    root
  end

  test "detects an Elixir/mix stack and its capabilities", %{base: base} do
    root = mkrepo(base, "elixir_app", [{"mix.exs", "defmodule X.MixProject do end"}])
    profile = Profiler.profile(root)

    assert profile.exists?
    assert profile.stack["language"] == "elixir"
    assert profile.stack["build_tool"] == "mix"
    assert %Capabilities{test_command: "mix test", package_manager: "mix"} = profile.capabilities
  end

  test "detects a Node stack", %{base: base} do
    root = mkrepo(base, "node_app", [{"package.json", "{}"}])
    profile = Profiler.profile(root)
    assert profile.stack["language"] == "node"
    assert profile.capabilities.test_command == "npm test"
  end

  test "detects a Python/uv stack", %{base: base} do
    root = mkrepo(base, "py_app", [{"pyproject.toml", "[project]"}])
    profile = Profiler.profile(root)
    assert profile.stack["language"] == "python"
    assert profile.capabilities.test_command == "uv run pytest"
  end

  test "a bare directory yields an unknown stack with a generic capability map", %{base: base} do
    root = mkrepo(base, "bare", [])
    profile = Profiler.profile(root)
    assert profile.stack["language"] == "unknown"
    assert profile.capabilities.test_command == nil
    assert profile.capabilities.spec_dir == "specs"
  end

  test "discovers .claude/commands, AGENTS.md/CLAUDE.md, and is fail-silent on git", %{base: base} do
    root =
      mkrepo(base, "conventions", [
        {".claude/commands/plan.md", "# plan"},
        {".claude/commands/build.md", "# build"},
        {"AGENTS.md", "# agents"}
      ])

    profile = Profiler.profile(root)
    assert profile.claude_commands == ["build", "plan"]
    assert profile.has_agents_md
    refute profile.has_claude_md
    # Non-git fixture: no remote/branch, never raises.
    refute profile.git?
    assert profile.git_remote == nil
  end

  test "a missing directory returns a partial, non-raising profile", %{base: base} do
    profile = Profiler.profile(Path.join(base, "does_not_exist"))
    refute profile.exists?
    assert profile.stack["language"] == "unknown"
    assert profile.claude_commands == []
  end
end
