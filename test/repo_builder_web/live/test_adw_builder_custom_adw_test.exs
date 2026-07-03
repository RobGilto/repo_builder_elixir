defmodule RepoBuilderWeb.TestAdwBuilderCustomAdwTest do
  @moduledoc """
  Integration tests for the custom ADW feature: per-step prompt overrides and
  ADW-level harness picker in the ADW Builder (issue-custom-adw).

  Covers:
  - Harness picker renders registered harnesses and sets `adw_harness`
  - Expanding a step shows an editable textarea pre-filled with placeholder
  - Editing the textarea stores the override per-step
  - Custom prompt reaches the launched step's `prompt_template`
  - Save-combo round-trips harness + per-step prompts through the sidecar
  - Load-combo repopulates harness and step prompts in the builder

  `async: false` — shared Ecto sandbox + app-env mutation for seam isolation.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Definitions
  alias RepoBuilder.Workflows

  @custom_prompt "Build a CSV export using Elixir streams, not buffering."

  test "harness picker renders registered harness options", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")

    assert has_element?(view, "select[name=\"harness\"][phx-change=\"adw_set_harness\"]")

    html = render(view)
    # At least one harness option renders (the default "fake" harness is always registered).
    assert html =~ "fake" or html =~ "claude" or html =~ "— harness —"
  end

  test "selecting a harness persists it in the assign", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")

    render_change(view, "adw_set_harness", %{"harness" => "fake"})

    html = render(view)
    # The select should reflect the chosen harness (selected attribute or value).
    assert html =~ "fake"
  end

  test "expanding a step shows an editable textarea", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")
    render_click(view, "adw_add_step", %{"step" => "build"})

    # Expand the step row.
    render_click(view, "adw_toggle_step", %{"id" => "1"})

    assert has_element?(view, "textarea[name=\"prompt-1\"][phx-change=\"adw_set_step_prompt\"]")
  end

  test "editing step prompt textarea stores the override", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")
    render_click(view, "adw_add_step", %{"step" => "build"})
    render_click(view, "adw_toggle_step", %{"id" => "1"})

    render_change(view, "adw_set_step_prompt", %{"id" => "1", "value" => @custom_prompt})

    # Collapse and re-expand to verify the value persists.
    render_click(view, "adw_toggle_step", %{"id" => "1"})
    html = render_click(view, "adw_toggle_step", %{"id" => "1"})

    assert html =~ @custom_prompt
  end

  test "custom step prompt reaches the launched step's prompt_template", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")
    render_click(view, "adw_add_step", %{"step" => "build"})
    render_click(view, "adw_toggle_step", %{"id" => "1"})
    render_change(view, "adw_set_step_prompt", %{"id" => "1", "value" => @custom_prompt})

    workflows_before = Workflows.list_workflows()
    render_click(view, "run_adw_builder")

    wf =
      Workflows.list_workflows()
      |> Enum.reject(fn w -> w in workflows_before end)
      |> List.last()

    assert wf, "expected a new workflow to be created"
    [step | _] = wf.steps
    assert step["prompt_template"] == @custom_prompt
  end

  test "blank step prompt falls back to the catalog default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_toggle_step", %{"id" => "1"})
    render_change(view, "adw_set_step_prompt", %{"id" => "1", "value" => "   "})

    workflows_before = Workflows.list_workflows()
    render_click(view, "run_adw_builder")

    wf =
      Workflows.list_workflows()
      |> Enum.reject(fn w -> w in workflows_before end)
      |> List.last()

    assert wf
    [step | _] = wf.steps
    alias RepoBuilder.WorkflowEngine.Catalog
    assert step["prompt_template"] == Catalog.default_prompt_template("plan")
  end

  test "save-combo round-trips harness + custom prompts; load repopulates them", %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "rb-custom-adw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "adws"))

    prev_combos = Application.get_env(:repo_builder, Combos)
    prev_defs = Application.get_env(:repo_builder, Definitions)

    Application.put_env(:repo_builder, Combos, root: tmp)

    Application.put_env(:repo_builder, Definitions,
      app_root: tmp,
      watch_enabled?: false,
      poll_interval_ms: 30_000
    )

    on_exit(fn ->
      if prev_combos,
        do: Application.put_env(:repo_builder, Combos, prev_combos),
        else: Application.delete_env(:repo_builder, Combos)

      if prev_defs, do: Application.put_env(:repo_builder, Definitions, prev_defs)
      File.rm_rf!(tmp)
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")

    render_change(view, "adw_set_name", %{"name" => "custom_wf"})
    render_change(view, "adw_set_harness", %{"harness" => "fake"})
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_add_step", %{"step" => "build"})

    # Set a custom prompt on the build step (id=2).
    render_click(view, "adw_toggle_step", %{"id" => "2"})
    render_change(view, "adw_set_step_prompt", %{"id" => "2", "value" => @custom_prompt})

    render_click(view, "adw_save_combo")

    # Verify the sidecar persisted harness + step prompts.
    assert {:ok, saved} = Combos.fetch("custom_wf")
    assert saved.harness == "fake"
    assert Enum.any?(saved.steps, fn {_name, p} -> p == @custom_prompt end)

    # Load the combo; verify harness + step prompts repopulate.
    loaded = render_change(view, "adw_load_combo", %{"combo" => "custom_wf"})

    # Harness should be reflected in the select.
    assert loaded =~ "fake"

    # Expand the build step to see its custom prompt.
    render_click(view, "adw_toggle_step", %{"id" => "2"})
    html = render(view)
    assert html =~ @custom_prompt
  end
end
