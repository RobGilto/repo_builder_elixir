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

  describe "UI surface + framework detection (design-system-plugins)" do
    test "a Phoenix mix.exs → web/phoenix", %{base: base} do
      root = mkrepo(base, "phx", [{"mix.exs", ~s(defp deps, do: [{:phoenix, "~> 1.8"}])}])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "web"
      assert profile.stack["framework"] == "phoenix"
    end

    test "a Ratatouille mix.exs → tui/ratatouille (TUI dep pins the surface)", %{base: base} do
      root = mkrepo(base, "rat", [{"mix.exs", ~s(defp deps, do: [{:ratatouille, "~> 0.5"}])}])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "tui"
      assert profile.stack["framework"] == "ratatouille"
    end

    test "a React package.json → web/react", %{base: base} do
      root = mkrepo(base, "react", [{"package.json", ~s({"dependencies":{"react":"^19"}})}])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "web"
      assert profile.stack["framework"] == "react"
    end

    test "an Ink package.json → tui/ink", %{base: base} do
      root = mkrepo(base, "ink", [{"package.json", ~s({"dependencies":{"ink":"^5"}})}])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "tui"
      assert profile.stack["framework"] == "ink"
    end

    test "a bubbletea go.mod → tui/bubbletea", %{base: base} do
      root =
        mkrepo(base, "bt", [
          {"go.mod", "module x\n\nrequire github.com/charmbracelet/bubbletea v1.2.0\n"}
        ])

      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "tui"
      assert profile.stack["framework"] == "bubbletea"
    end

    test "a plain elixir repo with no UI dep → surface none", %{base: base} do
      root = mkrepo(base, "plain", [{"mix.exs", "defmodule X.MixProject do end"}])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "none"
      assert profile.stack["framework"] == "none"
    end

    test "a bare directory → surface none", %{base: base} do
      root = mkrepo(base, "bare2", [])
      profile = Profiler.profile(root)
      assert profile.stack["surface"] == "none"
    end
  end
end
