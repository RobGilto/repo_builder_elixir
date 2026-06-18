defmodule RepoBuilderWeb.TestWorkingDirectoryTest do
  @moduledoc """
  Integration test for the configurable, persistent orchestrator + worker working
  directory, now driven from the prompt (⌘K) modal via a dialog directory picker
  (moved out of the General settings tab). The picker defaults to the project root,
  navigates the directory tree, and persists the chosen absolute path on the
  `orchestrators` row (the cwd the orchestrator and its workers spawn in). An
  unreadable/missing path is rejected with a flash and never opened or stored; the cwd
  can be cleared back to the isolated-workspace default.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{FileBrowser, Orchestrators}

  test "the directory picker defaults to the project root", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_dir_picker", %{})

    assert has_element?(view, "#dir-picker")
    assert has_element?(view, "#dir-picker-path", FileBrowser.project_root())
  end

  test "selecting a browsed directory persists it as the cwd", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "rb-wd-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_dir_picker", %{})
    render_click(view, "dir_picker_browse", %{"path" => dir})
    render_click(view, "dir_picker_select", %{})

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.working_dir == Path.expand(dir)
    assert has_element?(view, "#cmd-working-dir", Path.expand(dir))
    refute has_element?(view, "#dir-picker")
  end

  test "an unreadable/missing path is rejected with a flash and not persisted", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    bad = "/no/such/dir/#{System.unique_integer([:positive])}"
    html = render_click(view, "dir_picker_browse", %{"path" => bad})

    assert html =~ "Cannot open directory"
    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.working_dir == nil
  end

  test "clear resets a previously-set working directory", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "rb-wd-clear-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "open_dir_picker", %{})
    render_click(view, "dir_picker_browse", %{"path" => dir})
    render_click(view, "dir_picker_select", %{})
    {:ok, set} = Orchestrators.get_or_create_default()
    assert set.working_dir == Path.expand(dir)

    render_click(view, "clear_working_dir", %{})
    {:ok, cleared} = Orchestrators.get_or_create_default()
    assert cleared.working_dir == nil
  end
end
