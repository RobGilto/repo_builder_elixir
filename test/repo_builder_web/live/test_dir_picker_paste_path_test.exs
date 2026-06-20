defmodule RepoBuilderWeb.TestDirPickerPastePathTest do
  @moduledoc """
  Integration test for the paste-a-path directory picker. The picker's path field is an
  editable text input: submitting a typed/pasted absolute path (Enter or "Go") browses
  straight to that directory — re-listing its child directories and updating the path
  display — and "Use this directory" then commits it as the orchestrator cwd. A blank
  submit is a no-op; an invalid path flashes and leaves the prior listing intact.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  defp goto(view, path) do
    view
    |> element("form[phx-submit=dir_picker_goto]")
    |> render_submit(%{path: path})
  end

  test "submitting a pasted absolute path browses to it and lists its children", %{conn: conn} do
    base = Path.join(System.tmp_dir!(), "rb-paste-#{System.unique_integer([:positive])}")
    child = "nested-child"
    File.mkdir_p!(Path.join(base, child))
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "open_dir_picker", %{})

    # A trailing slash is normalized by Path.expand/1.
    html = goto(view, base <> "/")

    assert view |> element("#dir-picker-path") |> render() =~ Path.expand(base)
    assert html =~ child

    render_click(view, "dir_picker_select", %{})

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.working_dir == Path.expand(base)
    assert has_element?(view, "#cmd-working-dir", Path.expand(base))
    refute has_element?(view, "#dir-picker")
  end

  test "submitting an invalid path flashes and keeps the prior listing", %{conn: conn} do
    base = Path.join(System.tmp_dir!(), "rb-paste-prior-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "open_dir_picker", %{})
    goto(view, base)

    bad = "/no/such/dir/#{System.unique_integer([:positive])}"
    html = goto(view, bad)

    assert html =~ "Cannot open directory"
    # Path display unchanged — still the previously-browsed base.
    assert view |> element("#dir-picker-path") |> render() =~ Path.expand(base)

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.working_dir == nil
  end

  test "a blank submit is a no-op and does not flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "open_dir_picker", %{})

    html = goto(view, "   ")

    refute html =~ "Cannot open directory"
    assert has_element?(view, "#dir-picker")
  end
end
