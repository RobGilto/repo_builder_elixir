defmodule RepoBuilder.PluginsTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Commands.Resolver
  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.{Activation, Plugin}
  alias RepoBuilder.Projects
  alias RepoBuilder.WorkflowEngine.Catalog

  @lib Path.expand("plugin_library")

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "seam-#{System.unique_integer([:positive])}",
        root_path: "/tmp/seam-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  defp install_sample(id) do
    dir = Path.join(@lib, id)
    manifest = dir |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()

    {:ok, plugin} =
      Plugins.install_record(%{
        plugin_id: id,
        version: manifest["version"],
        source: "library",
        install_path: dir,
        manifest: manifest,
        status: :installed
      })

    plugin
  end

  describe "installed plugins" do
    test "install_record is idempotent and queryable" do
      assert %Plugin{plugin_id: "sample-commands", version: "1.0.0"} =
               install_sample("sample-commands")

      # re-install same version updates rather than duplicating
      _ = install_sample("sample-commands")

      assert [%Plugin{}] =
               Plugins.list_installed() |> Enum.filter(&(&1.plugin_id == "sample-commands"))

      assert %Plugin{} = Plugins.get("sample-commands")
      assert Plugins.installed?("sample-commands")
      refute Plugins.installed?("does-not-exist")
    end
  end

  describe "per-project activation" do
    test "activate/deactivate scopes to a project", %{project: project} do
      install_sample("sample-commands")

      refute Plugins.active?(project.id, "sample-commands")
      assert {:ok, _} = Plugins.activate(project.id, "sample-commands")
      assert Plugins.active?(project.id, "sample-commands")
      # platform (nil) scope is independent of the project scope
      refute Plugins.active?(nil, "sample-commands")

      assert :ok = Plugins.deactivate(project.id, "sample-commands")
      refute Plugins.active?(project.id, "sample-commands")
    end

    test "list_active orders by priority", %{project: project} do
      install_sample("sample-commands")
      install_sample("sample-workflow")
      {:ok, _} = Plugins.activate(project.id, "sample-workflow", priority: 5)
      {:ok, _} = Plugins.activate(project.id, "sample-commands", priority: 1)

      assert ["sample-commands", "sample-workflow"] =
               project.id |> Plugins.list_active() |> Enum.map(& &1.plugin_id)
    end
  end

  describe "Activation.effective/1 (the behaviour-per-project engine)" do
    test "different projects get different effective contribution sets", %{project: project} do
      install_sample("sample-commands")

      {:ok, other} =
        Projects.create_project(%{
          name: "other-#{System.unique_integer([:positive])}",
          root_path: "/tmp/other-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Plugins.activate(project.id, "sample-commands")

      assert [
               %Activation.Resolved{
                 kind: :command_pack,
                 plugin_id: "sample-commands",
                 abs_path: abs
               }
             ] =
               Activation.contributions(project.id, :command_pack)

      assert String.ends_with?(abs, "/commands")
      assert [] == Activation.contributions(other.id, :command_pack)
    end
  end

  describe "seam: command pack" do
    test "an active plugin contributes a slash command", %{project: project} do
      install_sample("sample-commands")
      {:ok, _} = Plugins.activate(project.id, "sample-commands")

      assert {:ok, resolved} = Resolver.resolve(project, "ship-it")
      assert resolved.layer == :plugin
      assert resolved.pack == "sample-commands"
      assert resolved.body =~ "Ship It"
      # resolve_all surfaces the plugin command name too
      assert "ship-it" in Enum.map(Resolver.resolve_all(project), & &1.name)
    end

    test "the command is absent for a project without the plugin", %{project: project} do
      install_sample("sample-commands")
      assert {:error, :not_found} = Resolver.resolve(project, "ship-it")
    end
  end

  describe "seam: workflow catalog (code→data)" do
    test "an active plugin contributes a launchable ADW type", %{project: project} do
      install_sample("sample-workflow")
      {:ok, _} = Plugins.activate(project.id, "sample-workflow")

      slugs = project.id |> Catalog.types() |> Enum.map(& &1.slug)
      assert "plan_build_ship" in slugs
      # built-in types are still present
      assert "plan_build" in slugs

      assert {:ok, type} = Catalog.fetch("plan_build_ship", project.id)
      assert type.label == "Plan → Build → Ship"

      assert {:ok, steps} = Catalog.steps("plan_build_ship", "claude", project.id)
      assert length(steps) == 3
      assert Enum.map(steps, & &1["name"]) == ["plan", "build", "ship"]
      # the harness was substituted into the data-defined steps
      assert Enum.all?(steps, &(&1["harness"] == "claude"))
    end

    test "platform catalog (nil project) is just the built-ins" do
      slugs = nil |> Catalog.types() |> Enum.map(& &1.slug)
      refute "plan_build_ship" in slugs
      assert "plan_build" in slugs
    end
  end

  describe "seam: context fragment" do
    test "an active plugin's fragment is exposed for the system prompt", %{project: project} do
      dir = Path.join(System.tmp_dir!(), "rb_frag_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "context"))
      File.write!(Path.join(dir, "context/primer.md"), "Always run credo before shipping.")

      manifest = %{
        "id" => "frag",
        "name" => "Frag",
        "version" => "1.0.0",
        "contributions" => [%{"kind" => "context_fragment", "path" => "context/primer.md"}]
      }

      {:ok, _} =
        Plugins.install_record(%{
          plugin_id: "frag",
          version: "1.0.0",
          install_path: dir,
          manifest: manifest,
          status: :installed
        })

      {:ok, _} = Plugins.activate(project.id, "frag")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Activation.context_fragments(project.id) =~ "credo before shipping"
      assert Activation.context_fragments(nil) == ""
    end
  end
end
