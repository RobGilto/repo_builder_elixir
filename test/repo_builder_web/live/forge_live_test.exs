defmodule RepoBuilderWeb.ForgeLiveTest do
  @moduledoc """
  The `/forge` surface end-to-end (forge-meta-artifact-generation, Phase 5): walk
  project → kind → spec → preview → forge → activate, asserting the generation streams and
  activation reflects in the UI. Driven through an injected canned generate runner (the
  `:forge` `:generate_runner` seam) so CI needs no CLI.

  `async: false` so the shared Ecto sandbox reaches the LiveView and the spawned forge Task,
  and the `:forge`/`:plugins` config overrides are global.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Plugins
  alias RepoBuilder.Projects

  @valid_command """
  ---
  description: Runs the project smoke test and reports the result.
  ---

  # Smoke Test

  ## Purpose

  Run it.

  ## Workflow

  1. Run it.

  ## Report

  The result.
  """

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "rb_forgelive_#{uniq}")
    File.mkdir_p!(Path.join(base, "library"))

    canned = fn %{scratch_dir: scratch} ->
      file = Path.join([scratch, "commands", "smoke-test.md"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, @valid_command)
      {:ok, [%{path: "commands/smoke-test.md", content: @valid_command}]}
    end

    prev_forge = Application.get_env(:repo_builder, :forge)
    prev_plugins = Application.get_env(:repo_builder, :plugins)

    Application.put_env(
      :repo_builder,
      :forge,
      Keyword.merge(prev_forge, generate_runner: canned, scratch_base: Path.join(base, "scratch"))
    )

    Application.put_env(
      :repo_builder,
      :plugins,
      Keyword.merge(prev_plugins,
        install_dir: Path.join(base, "install"),
        library_dir: Path.join(base, "library")
      )
    )

    on_exit(fn ->
      Application.put_env(:repo_builder, :forge, prev_forge)
      Application.put_env(:repo_builder, :plugins, prev_plugins)
      File.rm_rf(base)
    end)

    {:ok, project} =
      Projects.create_project(%{name: "fl-#{uniq}", root_path: "/tmp/fl-#{uniq}"})

    %{project: project}
  end

  defp await_installed(plugin_id, attempts \\ 400) do
    cond do
      Plugins.installed?(plugin_id) -> :ok
      attempts > 0 -> Process.sleep(20) && await_installed(plugin_id, attempts - 1)
      true -> :timeout
    end
  end

  test "walks compose → preview → forge → activated", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/forge")

    assert has_element?(view, "#forge-form")

    render_submit(element(view, "#forge-form"), %{
      "project_id" => project.id,
      "kind" => "command",
      "spec" => "a smoke-test command"
    })

    # The rendered generator prompt previews before any generation runs.
    assert has_element?(view, "#forge-preview")
    assert render(view) =~ "Rendered generator prompt"

    render_click(view, "forge", %{})
    assert has_element?(view, "#forge-progress")

    # The spawned forge Task drives generate → validate → package → install → activate.
    assert :ok = await_installed("smoke-test")
    assert Plugins.active?(project.id, "smoke-test")

    # The UI reflects activation (after the final progress broadcast lands).
    assert wait_for_badge(view)
  end

  defp wait_for_badge(view, attempts \\ 50) do
    cond do
      render(view) =~ "Activated" -> true
      attempts > 0 -> Process.sleep(20) && wait_for_badge(view, attempts - 1)
      true -> false
    end
  end
end
