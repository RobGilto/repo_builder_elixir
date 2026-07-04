defmodule RepoBuilderWeb.TestAdwBuilderCombosTest do
  @moduledoc """
  Integration test for the ⌘K ADW Builder's spec + initial-prompt inputs and a
  non-empty launch (Phase 1 of issue-adw-builder-combos).

  The builder now exposes a **Spec** and an **Initial prompt** textarea, holds them
  as assigns across re-renders, and `launch_adw_builder/4` threads them into the run
  as `%{"input" => …, "spec" => …}` while giving each step a real `prompt_template`
  from `Catalog.default_prompt_template/1` — so a hand-built ADW runs with real
  prompts instead of the empty-string default.

  `async: false` so the shared Ecto sandbox reaches the LiveView (and the launched
  workflow) process. Assertions read persisted `Workflows` state, not internals, and
  leave room to extend for the later Save/Load combo phases.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Definitions
  alias RepoBuilder.WorkflowEngine.Catalog
  alias RepoBuilder.Workflows

  @initial_prompt "Add a CSV export button to the reports page"
  @spec_text "The button lives next to the date filter and streams a .csv download."

  test "the builder renders Spec + Initial-prompt textareas and launches with real prompts", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # Open the ADW Builder mode.
    html = render_click(view, "toggle_adw_builder")

    # Both textareas render (by name, matching the phx-change targets).
    assert has_element?(view, "textarea[name=\"spec\"][phx-change=\"adw_set_spec\"]")
    assert has_element?(view, "textarea[name=\"prompt\"][phx-change=\"adw_set_prompt\"]")
    assert html =~ "INITIAL PROMPT"
    assert html =~ "SPEC (optional)"

    # Type the spec + initial prompt; they persist across re-renders while the modal is open.
    render_change(view, "adw_set_spec", %{"spec" => @spec_text})
    persisted = render_change(view, "adw_set_prompt", %{"prompt" => @initial_prompt})
    assert persisted =~ @initial_prompt
    assert persisted =~ @spec_text

    # Add an ordered chain of steps.
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_add_step", %{"step" => "build"})

    workflows_before = Workflows.list_workflows()

    # Launch.
    render_click(view, "run_adw_builder")

    # A workflow run was created. Find the freshly-built one (name-collision-safe).
    wf =
      Workflows.list_workflows()
      |> Enum.reject(fn w -> w in workflows_before end)
      |> List.last()

    assert wf, "expected a new workflow to be created on launch"
    assert wf.type == "custom"

    # The first step got a real, non-empty prompt_template from the canonical map, and
    # rendering it against the typed initial prompt (the `{{input}}` artifact) yields the
    # typed text — proving the empty-prompt gap is closed.
    [first_step | _] = wf.steps
    template = first_step["prompt_template"]
    assert template == Catalog.default_prompt_template("plan")
    assert template != ""

    assert render_template(template, %{"input" => @initial_prompt, "spec" => @spec_text}) =~
             @initial_prompt

    # Second step chains from the first and builds from the plan.
    assert first_step["on_success"] == "build"
  end

  test "launching with a blank spec and prompt still succeeds (name-only fallback)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "toggle_adw_builder")
    render_click(view, "adw_add_step", %{"step" => "plan"})

    workflows_before = Workflows.list_workflows()
    render_click(view, "run_adw_builder")

    wf =
      Workflows.list_workflows()
      |> Enum.reject(fn w -> w in workflows_before end)
      |> List.last()

    assert wf, "expected a workflow even with blank spec + prompt"
  end

  test "Phase 3: save materializes sidecar + script, palette shows the chip, load repopulates", %{
    conn: conn
  } do
    # Point BOTH the combos root (Combos test seam) and the Definitions app_root at a
    # throwaway dir so the generated script + sidecar land there and the palette scans
    # it as an :app (BASE-tab) ADW — no touching the real repo's adws/.
    tmp = Path.join(System.tmp_dir!(), "rb-combos-#{System.unique_integer([:positive])}")
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

    # Build a plan → build → review combo named "demo_pbr" with spec + prompt defaults.
    render_change(view, "adw_set_name", %{"name" => "demo_pbr"})
    render_change(view, "adw_set_spec", %{"spec" => @spec_text})
    render_change(view, "adw_set_prompt", %{"prompt" => @initial_prompt})
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_add_step", %{"step" => "build"})
    render_click(view, "adw_add_step", %{"step" => "review"})

    # Save the combo.
    render_click(view, "adw_save_combo")

    # 1. The JSON sidecar AND the generated .py exist on disk.
    sidecar = Path.join([tmp, "adws", ".combos", "demo_pbr.json"])
    script = Path.join([tmp, "adws", "adw_demo_pbr_iso.py"])
    assert File.exists?(sidecar), "expected the combo sidecar at #{sidecar}"
    assert File.exists?(script), "expected the generated script at #{script}"

    # 2. Combos.list includes it (round-trips through the context).
    names = Combos.list(nil) |> Enum.map(& &1.name)
    assert "demo_pbr" in names

    # 3. After the definitions refresh/broadcast the ADWs palette re-renders a chip for
    # the new slug (the generated script is scanned as an :app ADW → BASE tab). The
    # palette lives in COMMAND mode, so toggle out of the builder to see it.
    adws = Definitions.list(:adw, nil)
    assert Enum.any?(adws, &(&1.name == "demo_pbr_iso"))
    send(view.pid, {:definitions_changed, :adw, adws})
    render_click(view, "toggle_adw_builder")
    assert element(view, "#palette-adws-base") |> render() =~ "demo_pbr_iso"

    # 4. Loading the combo repopulates the builder step rows + textareas.
    render_click(view, "toggle_adw_builder")
    loaded = render_change(view, "adw_load_combo", %{"combo" => "combo:demo_pbr"})
    # Step rows now label the COMMAND/md each step runs (plan→feature, build→implement).
    assert loaded =~ "feature"
    assert loaded =~ "implement"
    assert loaded =~ "review"
    assert loaded =~ @spec_text
    assert loaded =~ @initial_prompt
  end

  test "the builder inputs live inside a <form> so phx-change fires (regression)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")

    # LiveView refuses phx-change on an input that is not inside a form ("form events
    # require the input to be inside a form"), which silently swallowed every keystroke
    # in the real browser. Assert the name input actually has a <form> ancestor.
    assert has_element?(view, "form input#adw-combo-name[phx-change=\"adw_set_name\"]")
  end

  test "adw_set_step_prompt reads the form-keyed value (prompt-<id>), not \"value\"", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "toggle_adw_builder")

    # Add a step (id 1) and expand it so its prompt textarea (name="prompt-1") renders.
    render_click(view, "adw_add_step", %{"step" => "plan"})
    render_click(view, "adw_toggle_step", %{"id" => "1"})

    # Inside a form, the changed textarea's value arrives keyed by its name, not "value".
    html =
      render_change(view, "adw_set_step_prompt", %{
        "id" => "1",
        "prompt-1" => "a bespoke plan prompt"
      })

    # The custom prompt persisted and re-renders into the textarea.
    assert html =~ "a bespoke plan prompt"
  end

  # Mirrors `Runner.render/2`'s documented `{{key}}` substitution contract (not internals):
  # a template resolves against a run's string-keyed artifacts.
  @spec render_template(String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  defp render_template(template, artifacts) do
    Enum.reduce(artifacts, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end
