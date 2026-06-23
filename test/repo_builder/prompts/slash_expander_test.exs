defmodule RepoBuilder.Prompts.SlashExpanderTest do
  @moduledoc """
  Unit tests for control-owned slash-command expansion. Each test plants real
  `.claude/commands/**/*.md` fixtures under a `tmp_dir` and passes that dir as the
  `working_dir`, so the merge/override + body-extraction path is exercised end-to-end.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Prompts.SlashExpander

  @moduletag :tmp_dir

  # Write a command file at `<tmp>/.claude/commands/<rel>.md` with optional frontmatter.
  defp write_command(tmp_dir, rel, body, frontmatter \\ "description: a test command") do
    path = Path.join([tmp_dir, ".claude", "commands", rel <> ".md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}\n")
    path
  end

  test "a known command expands to its file body", %{tmp_dir: tmp} do
    write_command(tmp, "greet", "Hello from the greet command.")

    assert SlashExpander.expand("/greet", tmp) == "Hello from the greet command."
  end

  test "$ARGUMENTS and positional placeholders are substituted", %{tmp_dir: tmp} do
    write_command(tmp, "deploy", "Deploy $1 to $2. Full args: $ARGUMENTS")

    assert SlashExpander.expand("/deploy api prod", tmp) ==
             "Deploy api to prod. Full args: api prod"
  end

  test "an unfilled positional collapses to empty", %{tmp_dir: tmp} do
    write_command(tmp, "deploy", "Target=$2 done")

    assert SlashExpander.expand("/deploy onlyone", tmp) == "Target= done"
  end

  test "args with no placeholder are appended to the body", %{tmp_dir: tmp} do
    write_command(tmp, "review", "Review the code carefully.")

    assert SlashExpander.expand("/review the auth module", tmp) ==
             "Review the code carefully.\n\nthe auth module"
  end

  test "a namespaced command resolves from nested dirs", %{tmp_dir: tmp} do
    write_command(tmp, "experts/ws/q", "Expert WS answer.")

    assert SlashExpander.expand("/experts:ws:q", tmp) == "Expert WS answer."
  end

  test "an unknown command is kept verbatim", %{tmp_dir: tmp} do
    assert SlashExpander.expand("/nope do a thing", tmp) == "/nope do a thing"
  end

  test "a reserved built-in is kept verbatim even with a planted file", %{tmp_dir: tmp} do
    write_command(tmp, "compact", "SHOULD NOT BE USED")

    assert SlashExpander.expand("/compact", tmp) == "/compact"
  end

  test "multiple leading invocations each expand; prose is untouched", %{tmp_dir: tmp} do
    write_command(tmp, "one", "FIRST")
    write_command(tmp, "two", "SECOND")

    prompt = "/one\nplain prose line\n/two with args"

    assert SlashExpander.expand(prompt, tmp) ==
             "FIRST\nplain prose line\nSECOND\n\nwith args"
  end

  describe "project-aware expansion (Commands.Resolver)" do
    alias RepoBuilder.Projects.Capabilities
    alias RepoBuilder.Projects.Project

    defp project(attrs) do
      base = %Project{
        id: Ecto.UUID.generate(),
        name: "p",
        root_path: nil,
        stack: %{"language" => "node"},
        capabilities: %{"language" => "node"} |> Capabilities.detect() |> Capabilities.to_map(),
        command_pack: "auto",
        command_pack_version: "latest",
        isolation_mode: :direct,
        status: :active
      }

      struct(base, attrs)
    end

    test "nil project falls back to today's path-based expansion", %{tmp_dir: tmp} do
      write_command(tmp, "greet", "Hello path-based.")
      assert SlashExpander.expand("/greet", tmp, nil) == "Hello path-based."
    end

    test "resolves a generic pack command with capability tokens filled (no working dir)" do
      proj = project(%{stack: %{"language" => "node"}})
      # `plan` lives only in the generic pack; tokens fill from the node capability map.
      expanded = SlashExpander.expand("/plan add a feature", nil, proj)
      assert expanded =~ "npm test"
      refute expanded =~ "{{TEST_COMMAND}}"
    end

    test "repo-local override wins and substitutes arguments", %{tmp_dir: tmp} do
      write_command(tmp, "build", "LOCAL BUILD for $ARGUMENTS")
      proj = project(%{root_path: tmp, stack: %{"language" => "elixir"}})
      assert SlashExpander.expand("/build the thing", tmp, proj) == "LOCAL BUILD for the thing"
    end

    test "reserved built-ins stay protected in project mode" do
      proj = project(%{stack: %{"language" => "node"}})
      assert SlashExpander.expand("/compact", nil, proj) == "/compact"
    end

    test "an unknown command passes through verbatim in project mode" do
      proj = project(%{stack: %{"language" => "node"}})
      assert SlashExpander.expand("/nope do a thing", nil, proj) == "/nope do a thing"
    end
  end

  test "a mid-line slash is not expanded", %{tmp_dir: tmp} do
    write_command(tmp, "greet", "EXPANDED")

    assert SlashExpander.expand("please run /greet now", tmp) == "please run /greet now"
  end

  test "a bare unix path is not expanded", %{tmp_dir: tmp} do
    assert SlashExpander.expand("/usr/local/bin/foo", tmp) == "/usr/local/bin/foo"
  end

  test "a command file without frontmatter keeps the original line", %{tmp_dir: tmp} do
    path = Path.join([tmp, ".claude", "commands", "broken.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "no frontmatter here, just text")

    # Discovered by name (the scanner is frontmatter-tolerant) but the body parse fails,
    # so the invocation degrades to the literal line — never a raise.
    assert SlashExpander.expand("/broken", tmp) == "/broken"
  end

  test "working_dir nil resolves app-root commands only and never raises" do
    # `/feature` ships in the repo's own .claude/commands; with nil working_dir the
    # app-root index still resolves it (proves nil is tolerated and app-root is scanned).
    expanded = SlashExpander.expand("/feature", nil)
    assert is_binary(expanded)
    assert expanded != "/feature"
  end

  test "an empty prompt is returned unchanged", %{tmp_dir: tmp} do
    assert SlashExpander.expand("", tmp) == ""
  end
end
