defmodule RepoBuilderWeb.TestAdwFlavorSelectorTest do
  @moduledoc """
  Integration tests for the ADW Builder three-way flavor selector (Iso / Local iso / Direct).

  Covers:
  - The selector renders all three flavor chips.
  - Selecting Direct and saving writes adw_<name>_direct.py and names it in the flash.
  - The saved combo round-trips flavor: :direct through fetch/2.
  - Selecting Iso / Local iso still produces the existing suffixes (no regression).
  - Loading a :direct combo restores the Direct chip selection.

  Uses the Application.get_env(:repo_builder, RepoBuilder.Adw.Combos)[:root] test seam
  so no real repo file is written. Pattern mirrors test_adw_builder_save_combo_test.exs.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Definitions

  setup do
    tmp = Path.join(System.tmp_dir!(), "rb-flavor-sel-#{System.unique_integer([:positive])}")
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

  describe "flavor selector rendering" do
    test "shows all three flavor chips when the builder is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      html = render(view)

      assert html =~ "phx-value-flavor=\"iso\""
      assert html =~ "phx-value-flavor=\"local_iso\""
      assert html =~ "phx-value-flavor=\"direct\""
    end

    test "Iso chip starts active by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      html = render(view)

      # The Iso chip carries cns-chip--active; others do not.
      assert html =~ ~r/cns-chip--active[^>]*>[^<]*Iso/s
    end
  end

  describe "selecting Direct flavor and saving" do
    test "saves adw_<name>_direct.py and names it in the flash", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      render_click(view, "adw_set_flavor", %{"flavor" => "direct"})
      render_click(view, "adw_add_step", %{"step" => "plan"})
      render_click(view, "adw_add_step", %{"step" => "build"})
      render_change(view, "adw_set_name", %{"name" => "my_direct_wf"})

      render_click(view, "adw_save_combo")

      # Script file written with _direct suffix.
      script = Path.join([tmp, "adws", "adw_my_direct_wf_direct.py"])
      assert File.exists?(script), "expected _direct.py at #{script}"

      # Sidecar written.
      sidecar = Path.join([tmp, "adws", ".combos", "my_direct_wf.json"])
      assert File.exists?(sidecar), "expected sidecar at #{sidecar}"

      # Flash names the direct script.
      html = render(view)
      assert html =~ "adw_my_direct_wf_direct.py"

      # Saved combo has flavor: :direct.
      assert {:ok, combo} = Combos.fetch("my_direct_wf", tmp)
      assert combo.flavor == :direct
    end

    test "generated _direct.py delegates to run_local_workflow with isolated=False", %{
      conn: conn,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      render_click(view, "adw_set_flavor", %{"flavor" => "direct"})
      render_click(view, "adw_add_step", %{"step" => "plan"})
      render_change(view, "adw_set_name", %{"name" => "iso_false_check"})
      render_click(view, "adw_save_combo")

      script_text = File.read!(Path.join([tmp, "adws", "adw_iso_false_check_direct.py"]))
      assert script_text =~ "run_local_workflow(adw_id, STEPS, logger, isolated=False)"
    end
  end

  describe "Iso and Local iso flavors still work (no regression)" do
    test "Iso flavor saves adw_<name>_iso.py", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      render_click(view, "adw_add_step", %{"step" => "plan"})
      render_change(view, "adw_set_name", %{"name" => "regression_iso"})
      render_click(view, "adw_save_combo")

      assert File.exists?(Path.join([tmp, "adws", "adw_regression_iso_iso.py"]))
    end

    test "Local iso flavor saves adw_<name>_local_iso.py", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      render_click(view, "adw_set_flavor", %{"flavor" => "local_iso"})
      render_click(view, "adw_add_step", %{"step" => "plan"})
      render_change(view, "adw_set_name", %{"name" => "regression_local"})
      render_click(view, "adw_save_combo")

      assert File.exists?(Path.join([tmp, "adws", "adw_regression_local_local_iso.py"]))
    end
  end

  describe "loading a :direct combo" do
    test "restores the Direct chip selection", %{conn: conn, tmp: tmp} do
      # Pre-save a :direct combo so there is something to load.
      assert {:ok, _combo} =
               Combos.save(
                 %{
                   name: "loadable_direct",
                   steps: [{:plan, nil}],
                   flavor: :direct,
                   spec: nil,
                   initial_prompt: nil
                 },
                 tmp
               )

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      render_change(view, "adw_load_combo", %{"combo" => "combo:loadable_direct"})

      html = render(view)
      # The Direct chip now carries cns-chip--active.
      assert html =~ ~r/cns-chip--active[^>]*>[^<]*Direct/s
    end
  end

  describe "unknown flavor from phx-value" do
    test "unknown flavor string defaults to :iso without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      # Simulate a JS-tampered or future unknown flavor value.
      render_click(view, "adw_set_flavor", %{"flavor" => "deploy"})

      # LiveView is still alive and the Iso chip is active (default fallback).
      assert is_pid(view.pid) and Process.alive?(view.pid)
      html = render(view)
      assert html =~ ~r/cns-chip--active[^>]*>[^<]*Iso/s
    end
  end
end
