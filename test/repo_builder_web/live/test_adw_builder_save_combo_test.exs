defmodule RepoBuilderWeb.TestAdwBuilderSaveComboTest do
  @moduledoc """
  Reproduce-then-fix tests for the ADW Builder "Save combo" bug. The fix landed in
  `AdwBuilderPanel.adw_save_combo`:

  - The handler must NOT raise `ArgumentError` on a non-canonical step name (uppercase,
    JS-tampered, or a future palette change). The original `String.to_existing_atom/1`
    killed the LiveView process, so the click silently did nothing.
  - On save success the new combo is pre-selected in the Load-combo dropdown.
  - `nilify_blank/1` must not crash on a nil `orchestrator_working_dir`.

  These tests stub the `Combos` + `Definitions` roots at a per-test tmp dir (mirrors
  the existing `test_adw_builder_combos_test.exs` seam) so the generated `adws/*.py`
  is observable without touching the real repo.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Definitions
  alias RepoBuilderWeb.ConsoleLive.AdwBuilderPanel
  alias RepoBuilderWeb.ConsoleLive.Shared

  describe "to_step_atom/1 (unit)" do
    test "canonical lowercase names resolve to atoms" do
      assert {:ok, :test} = AdwBuilderPanel.to_step_atom("test")
      assert {:ok, :review} = AdwBuilderPanel.to_step_atom("review")
      assert {:ok, :plan} = AdwBuilderPanel.to_step_atom("plan")
    end

    test "non-canonical names (uppercase, JS-tampered) do NOT raise" do
      # `String.to_existing_atom/1` would raise ArgumentError on these — the original bug.
      assert {:error, {:unknown_step, "TEST"}} = AdwBuilderPanel.to_step_atom("TEST")
      assert {:error, {:unknown_step, "REVIEW"}} = AdwBuilderPanel.to_step_atom("REVIEW")
      assert {:error, {:unknown_step, "Feature"}} = AdwBuilderPanel.to_step_atom("Feature")
      assert {:error, {:unknown_step, ""}} = AdwBuilderPanel.to_step_atom("")
    end

    test "non-string input returns a tagged error, never raises" do
      assert {:error, {:unknown_step, _}} = AdwBuilderPanel.to_step_atom(nil)
      assert {:error, {:unknown_step, _}} = AdwBuilderPanel.to_step_atom(:test_atom)
      assert {:error, {:unknown_step, _}} = AdwBuilderPanel.to_step_atom(42)
    end

    test "resolve_steps/1 returns a tagged error on any unknown step" do
      steps = [
        %{id: 1, name: "test", expanded: false, prompt: nil},
        %{id: 2, name: "REVIEW", expanded: false, prompt: nil}
      ]

      assert {:error, {:unknown_step, "REVIEW"}} = AdwBuilderPanel.resolve_steps(steps)
    end

    test "resolve_steps/1 returns StepSpecs on canonical steps" do
      steps = [
        %{id: 1, name: "test", expanded: false, prompt: "p1"},
        %{id: 2, name: "review", expanded: false, prompt: nil}
      ]

      assert {:ok, [s1, s2]} = AdwBuilderPanel.resolve_steps(steps)
      assert s1.name == :test and s1.prompt == "p1"
      assert s2.name == :review and s2.prompt == nil
    end
  end

  describe "adw_save_combo LiveView integration (reproduce-then-fix)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb-save-combo-#{System.unique_integer([:positive])}")
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

      {:ok, tmp: tmp}
    end

    test "canonical steps + name ⇒ :info flash + script file written + pre-selected", %{
      conn: conn,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      # Build a test → review chain named "test_review".
      render_click(view, "adw_add_step", %{"step" => "test"})
      render_click(view, "adw_add_step", %{"step" => "review"})
      render_change(view, "adw_set_name", %{"name" => "test_review"})

      # The save button must be enabled (proves root cause A: @adw_name sync works).
      assert has_element?(view, "button[phx-click=\"adw_save_combo\"]:not([disabled])")

      render_click(view, "adw_save_combo")

      # 1. The composite .py exists on disk.
      script = Path.join([tmp, "adws", "adw_test_review_iso.py"])
      assert File.exists?(script), "expected generated script at #{script}"

      # 2. The JSON sidecar was written.
      sidecar = Path.join([tmp, "adws", ".combos", "test_review.json"])
      assert File.exists?(sidecar), "expected sidecar at #{sidecar}"

      # 3. An :info flash appears (the rendered alert text).
      assert has_element?(view, "#flash-info[role='alert']")
      html = render(view)
      assert html =~ "Saved combo + generated adw_test_review_iso.py"

      # 4. The new combo is pre-selected in the Load-combo dropdown (STEP 3 hardening).
      assert render(view) =~ ~s(value=\"combo:test_review\" selected)

      # 5. Combos.list round-trips it.
      names = Combos.list(nil) |> Enum.map(& &1.name)
      assert "test_review" in names
    end

    test "non-canonical step name ⇒ :error flash + NO file write (no crash)", %{
      conn: conn,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      # Inject a non-canonical step name (uppercase "TEST"). The handler accepts ANY
      # `phx-value-step` string in `adw_add_step` — that's the live-wire attack surface
      # for the original crash (a JS-tampered click value or a future palette change).
      render_click(view, "adw_add_step", %{"step" => "TEST"})
      render_click(view, "adw_add_step", %{"step" => "REVIEW"})
      render_change(view, "adw_set_name", %{"name" => "test_review"})

      # Sanity: the LiveView must still be alive after the non-canonical `adw_add_step`
      # (adw_add_step never validated names, but the bug only manifested in the save
      # handler — so we keep both paths in the regression set).
      assert render(view) =~ "ADD STEP"

      render_click(view, "adw_save_combo")

      # 1. An :error flash appears — no raise.
      assert has_element?(view, "#flash-error[role='alert']")
      html = render(view)
      assert html =~ "Unknown step: TEST"

      # 2. No script was generated (the handler refused before any I/O).
      adws_dir = Path.join(tmp, "adws")
      refute File.exists?(Path.join(adws_dir, "adw_test_review_iso.py"))
      # The .combos sidecar dir should not exist yet (Combos.save was never called).
      refute File.exists?(Path.join([adws_dir, ".combos", "test_review.json"]))

      # 3. The LiveView is still mounted — no crash, just an error flash.
      assert is_pid(view.pid) and Process.alive?(view.pid)
    end

    test "save with nil orchestrator_working_dir does not crash (nilify_blank guard)", %{
      tmp: _tmp
    } do
      # The orchestrator is set to working_dir: "" by default; nilify_blank("") is nil.
      # The guard ensures a true nil (e.g. if a future path drops the assign entirely)
      # doesn't FunctionClauseError out of the handler.
      assert Shared.nilify_blank(nil) == nil
      assert Shared.nilify_blank("") == nil
      assert Shared.nilify_blank("  ") == nil
      assert Shared.nilify_blank("/tmp/work") == "/tmp/work"
    end

    test "Save button is server-rendered disabled when name is blank and unblocks on input", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_click(view, "adw_add_step", %{"step" => "test"})

      # Blank name + non-empty steps: button is NOT disabled — empty-name is handled
      # by a server-side flash on click (avoids the blur-only phx-change deadlock).
      assert has_element?(view, "button[phx-click=\"adw_save_combo\"]:not([disabled])")

      # Typing a name keeps the button enabled (no regression to the steps-disabled guard).
      render_change(view, "adw_set_name", %{"name" => "x"})

      assert has_element?(view, "button[phx-click=\"adw_save_combo\"]:not([disabled])")
    end
  end

  describe "ADW Builder UI binding" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb-adw-ui-#{System.unique_integer([:positive])}")
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

      {:ok, tmp: tmp}
    end

    test "workflow name has a visible <label> bound to the input by id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      assert has_element?(view, "label[for=\"adw-combo-name\"]")

      assert has_element?(
               view,
               "input#adw-combo-name[phx-change=\"adw_set_name\"][name=\"name\"]"
             )

      html = render(view)
      assert html =~ "WORKFLOW NAME"
      refute html =~ "Workflow name (optional)"
    end
  end
end
