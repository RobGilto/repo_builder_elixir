defmodule RepoBuilder.Commands.ProvisionerTest do
  @moduledoc """
  The ADW command provisioner (issue-adw-portable-commands): writes the resolved,
  token-filled command bodies into a target repo's `.claude/commands/`, idempotently,
  repo-owned files always winning, fail-soft. Uses tmp roots + in-memory `Project`
  structs over the shipped `priv/command_packs` packs, so async.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Commands.Provisioner
  alias RepoBuilder.Definitions.Adw
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.Project

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "rb_provisioner_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp project(root, attrs \\ []) do
    base = %Project{
      id: Ecto.UUID.generate(),
      name: "p",
      root_path: root,
      stack: %{"language" => "elixir"},
      capabilities: %{"language" => "elixir"} |> Capabilities.detect() |> Capabilities.to_map(),
      command_pack: "auto",
      command_pack_version: "latest",
      isolation_mode: :direct,
      status: :active
    }

    struct(base, attrs)
  end

  defp commands_path(root, name), do: Path.join([root, ".claude", "commands", name <> ".md"])

  describe "provision/2" do
    test "writes missing commands with provenance frontmatter + filled body" do
      root = tmp_root()
      proj = project(root)

      assert {:ok, provisioned} = Provisioner.provision(proj, ["plan", "build"])
      assert Enum.sort(provisioned) == ["build", "plan"]

      plan = commands_path(root, "plan")
      build = commands_path(root, "build")
      assert File.regular?(plan)
      assert File.regular?(build)

      body = File.read!(build)
      # Provenance marker, both human comment and machine key.
      assert body =~ "provisioned_by: repo_builder"
      assert body =~ "provisioned-by: repo_builder"
      # Elixir stack pack body, capability tokens filled (no dangling `{{…}}`).
      assert body =~ "mix compile --warnings-as-errors"
      refute body =~ "{{"
    end

    test "never overwrites a repo-owned command and excludes it from the result" do
      root = tmp_root()
      proj = project(root)

      own = commands_path(root, "build")
      File.mkdir_p!(Path.dirname(own))
      File.write!(own, "REPO OWNS THIS")

      assert {:ok, provisioned} = Provisioner.provision(proj, ["build", "plan"])

      # build is repo-owned: untouched + excluded; plan is written.
      assert provisioned == ["plan"]
      assert File.read!(own) == "REPO OWNS THIS"
      assert File.regular?(commands_path(root, "plan"))
    end

    test "skips an unresolvable command without error and excludes it" do
      root = tmp_root()
      proj = project(root)

      assert {:ok, provisioned} = Provisioner.provision(proj, ["plan", "totally-nonexistent-cmd"])
      assert provisioned == ["plan"]
      refute File.exists?(commands_path(root, "totally-nonexistent-cmd"))
    end

    test "no-ops cleanly when nothing resolves" do
      root = tmp_root()
      proj = project(root)

      assert {:ok, []} = Provisioner.provision(proj, ["totally-nonexistent-cmd"])
    end

    test "fail-soft: an unwritable target yields {:error, _}, never a raise" do
      root = tmp_root()
      # Make `.claude` a regular FILE so `mkdir_p` of `.claude/commands` fails (ENOTDIR).
      File.mkdir_p!(root)
      File.write!(Path.join(root, ".claude"), "not a dir")
      proj = project(root)

      assert {:error, _reason} = Provisioner.provision(proj, ["plan"])
    end

    test "returns {:error, :no_root_path} when the project has no root" do
      proj = project(nil)
      assert {:error, :no_root_path} = Provisioner.provision(proj, ["plan"])
    end
  end

  describe "required_commands/1" do
    test "parses portable Step slash-command declarations in first-seen order" do
      adw = %Adw{
        name: "pbr",
        path:
          write_script("""
          STEPS = [
              Step("plan", "/plan"),
              Step("build", "/build"),
              Step("review", "/review"),
          ]
          """),
        source: :app,
        description: nil,
        mtime: 0
      }

      assert Provisioner.required_commands(adw) == ["plan", "build", "review"]
    end

    test "parses slash_command assignments and strips arg suffixes" do
      adw = %Adw{
        name: "iso",
        path:
          write_script("""
              slash_command="/test",
              Step("scout_architecture", "/scout architecture"),
          """),
        source: :app,
        description: nil,
        mtime: 0
      }

      assert Provisioner.required_commands(adw) == ["test", "scout"]
    end

    test "falls back to the standard set for an empty or unreadable script" do
      empty = %Adw{
        name: "e",
        path: write_script("# nothing here\n"),
        source: :app,
        mtime: 0,
        description: nil
      }

      assert Provisioner.required_commands(empty) == ~w(plan build review test fix)

      missing = %Adw{
        name: "m",
        path:
          Path.join(System.tmp_dir!(), "no_such_adw_#{System.unique_integer([:positive])}.py"),
        source: :app,
        mtime: 0,
        description: nil
      }

      assert Provisioner.required_commands(missing) == ~w(plan build review test fix)
    end
  end

  describe "provision_for_adw/2" do
    test "resolves the script's required commands and seeds them" do
      root = tmp_root()
      proj = project(root)

      adw = %Adw{
        name: "pb",
        path:
          write_script("""
          STEPS = [Step("plan", "/plan"), Step("build", "/build")]
          """),
        source: :app,
        description: nil,
        mtime: 0
      }

      assert {:ok, provisioned} = Provisioner.provision_for_adw(proj, adw)
      assert Enum.sort(provisioned) == ["build", "plan"]
      assert File.regular?(commands_path(root, "plan"))
      assert File.regular?(commands_path(root, "build"))
    end
  end

  defp write_script(body) do
    path = Path.join(System.tmp_dir!(), "adw_script_#{System.unique_integer([:positive])}.py")
    File.write!(path, body)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
