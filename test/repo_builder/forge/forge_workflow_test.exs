defmodule RepoBuilder.Forge.WorkflowTest do
  @moduledoc """
  The forge ADW's deterministic edges + the package → install → activate tail
  (forge-meta-artifact-generation, Phases 3–4), driven through an injected canned generate
  runner (the registry-seam discipline) so CI needs no real CLI.

  async: false — overrides the app-wide `:plugins` (install/library dirs) + `:forge`
  (scratch base) config so generation, packaging, and install stay in tmp dirs.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Forge
  alias RepoBuilder.Forge.Workflow
  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.DesignSystem
  alias RepoBuilder.Projects

  @valid_command """
  ---
  description: Runs the project smoke test and reports the result.
  ---

  # Smoke Test

  ## Purpose

  Run the smoke test.

  ## Workflow

  1. Run it.

  ## Report

  Output the result.
  """

  @valid_design_system ~s({"surface":"web","stack":"elixir","framework":"phoenix","paradigm":"none","tokens":{"accent":"one accent; no purple gradient"},"components":[{"name":"input","tag":"<.input>","package":"core_components","when_to_use":"every form field"}],"rules":["Reach for an existing component tag before hand-rolling markup."],"references":["lib/repo_builder_web/components/core_components.ex"]})

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "rb_forge_#{uniq}")
    install = Path.join(base, "install")
    library = Path.join(base, "library")
    scratch = Path.join(base, "scratch")
    File.mkdir_p!(library)

    prev_plugins = Application.get_env(:repo_builder, :plugins)
    prev_forge = Application.get_env(:repo_builder, :forge)

    Application.put_env(
      :repo_builder,
      :plugins,
      Keyword.merge(prev_plugins, install_dir: install, library_dir: library)
    )

    Application.put_env(:repo_builder, :forge, Keyword.put(prev_forge, :scratch_base, scratch))

    on_exit(fn ->
      Application.put_env(:repo_builder, :plugins, prev_plugins)
      Application.put_env(:repo_builder, :forge, prev_forge)
      File.rm_rf(base)
    end)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
    %{counter: counter}
  end

  # A runner that writes the given files into the scratch dir and returns them, counting
  # its invocations through `counter`.
  defp canned_runner(counter, files) do
    fn %{scratch_dir: scratch} ->
      Agent.update(counter, &(&1 + 1))

      for %{path: rel, content: content} <- files do
        abs = Path.join(scratch, rel)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, content)
      end

      {:ok, files}
    end
  end

  test "a valid command is packaged, installed, and activated for its project", %{
    counter: counter
  } do
    {:ok, project} =
      Projects.create_project(%{
        name: "forge-#{System.unique_integer([:positive])}",
        root_path: "/tmp/forge-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Projects.create_project(%{
        name: "other-#{System.unique_integer([:positive])}",
        root_path: "/tmp/other-#{System.unique_integer([:positive])}"
      })

    {:ok, artifact} = Forge.request(%{kind: "command", spec: "smoke", project_id: project.id})
    runner = canned_runner(counter, [%{path: "commands/smoke-test.md", content: @valid_command}])

    assert {:ok, final} = Workflow.run(artifact, generate_runner: runner)
    assert final.status == :installed
    assert final.plugin_id == "smoke-test"
    assert Agent.get(counter, & &1) == 1

    # The forged plugin is installed and active for THIS project only.
    assert Plugins.installed?("smoke-test")
    assert Plugins.active?(project.id, "smoke-test")
    refute Plugins.active?(other.id, "smoke-test")
  end

  test "a valid design system is validated, packaged, installed, and resolves for its project",
       %{counter: counter} do
    {:ok, project} =
      Projects.create_project(%{
        name: "forge-ds-#{System.unique_integer([:positive])}",
        root_path: "/tmp/forge-ds-#{System.unique_integer([:positive])}",
        stack: %{"language" => "elixir", "surface" => "web", "framework" => "phoenix"}
      })

    {:ok, artifact} =
      Forge.request(%{
        kind: "design_system",
        spec: "phoenix design system",
        project_id: project.id
      })

    runner =
      canned_runner(counter, [
        %{path: "design/web-phoenix.json", content: @valid_design_system}
      ])

    assert {:ok, final} = Workflow.run(artifact, generate_runner: runner)
    assert final.status == :installed
    # id derived from the descriptor's surface-framework.
    assert final.plugin_id == "web-phoenix"
    assert Agent.get(counter, & &1) == 1

    # The forged descriptor parses through the strict boundary and is wired: an active
    # :design_system plugin makes the resolver source the design system from the plugin.
    assert Plugins.installed?("web-phoenix")
    assert Plugins.active?(project.id, "web-phoenix")
    assert {:ok, resolved} = DesignResolver.resolve(project)
    assert resolved.source == :plugin
    assert %DesignSystem{framework: "phoenix"} = resolved.descriptor
  end

  test "a malformed design system is rejected by validation (never installed)", %{
    counter: counter
  } do
    {:ok, artifact} = Forge.request(%{kind: "design_system", spec: "a broken design system"})
    # Unknown surface → DesignSystem.parse returns {:error, :unknown_surface}.
    bad = [
      %{
        path: "design/broken.json",
        content: ~s({"surface":"holographic","stack":"x","framework":"y"})
      }
    ]

    runner = canned_runner(counter, bad)

    assert {:ok, final} = Workflow.run(artifact, generate_runner: runner)
    assert final.status == :failed
    assert final.error["reason"] =~ "validation"
    # initial attempt + one retry (config max_retries: 1).
    assert Agent.get(counter, & &1) == 2
  end

  test "a malformed generation retries then fails cleanly", %{counter: counter} do
    {:ok, artifact} = Forge.request(%{kind: "command", spec: "a broken command"})
    bad = [%{path: "commands/Bad.md", content: "# no frontmatter and no sections"}]
    runner = canned_runner(counter, bad)

    assert {:ok, final} = Workflow.run(artifact, generate_runner: runner)
    assert final.status == :failed
    assert final.error["reason"] =~ "validation"
    # initial attempt + one retry (config max_retries: 1).
    assert Agent.get(counter, & &1) == 2
  end

  test "a generate transport error retries then fails (crash isolation)", %{counter: counter} do
    {:ok, artifact} = Forge.request(%{kind: "skill", spec: "a skill"})

    runner = fn _request ->
      Agent.update(counter, &(&1 + 1))
      {:error, :boom}
    end

    assert {:ok, final} = Workflow.run(artifact, generate_runner: runner)
    assert final.status == :failed
    assert final.error["reason"] =~ "generate"
    assert Agent.get(counter, & &1) == 2
  end

  test "session_generate refuses a non-real (fake) harness" do
    assert {:error, :no_real_harness} =
             Workflow.session_generate(%{
               kind: :command,
               harness: "fake",
               prompt: "x",
               scratch_dir: System.tmp_dir!(),
               agent_id: "forge-test"
             })
  end
end
