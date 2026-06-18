defmodule RepoBuilder.DefinitionsTest do
  @moduledoc """
  Unit tests for the file-driven prompt palette's pure scanners and the merged-root
  resolver: per-category `scan/2`, `:`-namespacing, frontmatter/docstring extraction,
  merge precedence (working-dir shadows app by name), empty dirs, and malformed-input
  tolerance. Filesystem reads only — no DB, no GenServer.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Definitions
  alias RepoBuilder.Definitions.Adw
  alias RepoBuilder.Definitions.Agent
  alias RepoBuilder.Definitions.SlashCommand

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  describe "SlashCommand.scan/2" do
    @tag :tmp_dir
    test "one struct per file with frontmatter description", %{tmp_dir: root} do
      write!(Path.join(root, ".claude/commands/feature.md"), """
      ---
      description: Plan a feature
      argument-hint: "[spec]"
      ---
      # Feature
      """)

      assert [%SlashCommand{} = cmd] = SlashCommand.scan(root, :app)
      assert cmd.name == "feature"
      assert cmd.namespace == []
      assert cmd.source == :app
      assert cmd.description == "Plan a feature"
      assert cmd.argument_hint == "[spec]"
      assert is_integer(cmd.mtime)
    end

    @tag :tmp_dir
    test "subdir commands are :-namespaced", %{tmp_dir: root} do
      write!(Path.join(root, ".claude/commands/experts/ws/q.md"), """
      ---
      description: nested
      ---
      body
      """)

      assert [%SlashCommand{name: "experts:ws:q", namespace: ["experts", "ws"]}] =
               SlashCommand.scan(root, :app)
    end

    @tag :tmp_dir
    test "malformed frontmatter degrades to description: nil, file still listed", %{tmp_dir: root} do
      write!(Path.join(root, ".claude/commands/broken.md"), "no frontmatter here at all\n")

      assert [%SlashCommand{name: "broken", description: nil}] = SlashCommand.scan(root, :app)
    end

    test "missing directory yields []" do
      assert SlashCommand.scan("/nonexistent/path/xyz", :app) == []
    end
  end

  describe "Adw.scan/2" do
    @tag :tmp_dir
    test "docstring first line becomes the description; prefix stripped", %{tmp_dir: root} do
      write!(Path.join(root, "adws/adw_plan_build_iso.py"), """
      #!/usr/bin/env python
      \"\"\"
      ADW Plan Build - does the planning and building

      More detail here.
      \"\"\"
      print("hi")
      """)

      assert [%Adw{} = adw] = Adw.scan(root, :app)
      assert adw.name == "plan_build_iso"
      assert adw.description == "ADW Plan Build - does the planning and building"
      assert adw.source == :app
    end

    @tag :tmp_dir
    test "no docstring falls back to humanized filename", %{tmp_dir: root} do
      write!(Path.join(root, "adws/adw_quick_fix.py"), "print('no docstring')\n")

      assert [%Adw{name: "quick_fix", description: "quick fix"}] = Adw.scan(root, :app)
    end

    test "missing directory yields []" do
      assert Adw.scan("/nonexistent/path/xyz", :app) == []
    end
  end

  describe "Agent.scan/1" do
    test "app agents come from Orchestrator.Templates.list/0" do
      names = Agent.scan(nil) |> Enum.map(& &1.name)
      # The shipped built-in template fixture is always present.
      assert "code-scout" in names
      assert Enum.all?(Agent.scan(nil), &(&1.source == :app))
    end

    @tag :tmp_dir
    test "working-dir .claude/agents overlay is tagged :working_dir", %{tmp_dir: root} do
      write!(Path.join(root, ".claude/agents/custom-helper.md"), """
      ---
      description: a working-dir agent
      ---
      You are helpful.
      """)

      agent = Agent.scan(root) |> Enum.find(&(&1.name == "custom-helper"))
      assert %Agent{source: :working_dir, description: "a working-dir agent"} = agent
    end
  end

  describe "resolve/2 merge precedence" do
    @tag :tmp_dir
    test "working-dir slash command shadows app entry of the same name", %{tmp_dir: root} do
      app_root = Path.join(root, "app")
      work_dir = Path.join(root, "work")

      write!(Path.join(app_root, ".claude/commands/dup.md"), """
      ---
      description: app version
      ---
      """)

      write!(Path.join(work_dir, ".claude/commands/dup.md"), """
      ---
      description: working version
      ---
      """)

      %{slash_command: slash} = Definitions.resolve(app_root, work_dir)
      dup = Enum.filter(slash, &(&1.name == "dup"))

      assert [%SlashCommand{source: :working_dir, description: "working version"}] = dup
    end

    @tag :tmp_dir
    test "empty merged root yields empty categories", %{tmp_dir: root} do
      assert %{slash_command: [], adw: []} = Definitions.resolve(root, nil)
    end
  end
end
