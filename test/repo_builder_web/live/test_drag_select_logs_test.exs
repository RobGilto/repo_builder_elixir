defmodule RepoBuilderWeb.TestDragSelectLogsTest do
  @moduledoc """
  LiveView integration for the SERVER contract of drag-select range selection
  (issue drag-select): the `select_drag` event adds/removes a batch of row ids over the
  existing `selected_ids` (honoring `mode`) in a single round-trip, re-streaming the
  changed rows so checkbox state reconciles the hook's optimistic paint.

  The raw pointer gesture is browser-only (covered by manual/Tidewave verification); here
  we drive the committed event via `render_hook/3` and assert the `selection_bar` count
  and per-row `checked` state.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  defp tool_call(id, name) do
    %Event.ToolCall{harness: :fake, id: id, name: name, input: %{"cmd" => "echo hi"}}
  end

  defp seed_rows(view) do
    Dashboard.broadcast_event("worker-a", tool_call("c1", "bash"), 11)
    Dashboard.broadcast_event("worker-a", tool_call("c2", "edit"), 12)
    Dashboard.broadcast_event("worker-a", tool_call("c3", "read"), 13)
    assert wait_render(view, "log-13")
  end

  defp checked?(view, row_id) do
    render(element(view, "#ev-row-#{row_id} input.cns-event-row__select")) =~ "checked"
  end

  test "select_drag selects a contiguous range in one round-trip", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_hook(view, "select_drag", %{"ids" => ["1", "2", "3"], "mode" => "select"})

    assert render(view) =~ "3 selected"
    assert checked?(view, 1) and checked?(view, 2) and checked?(view, 3)
  end

  test "select_drag deselect removes a subset, leaving the rest checked", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_hook(view, "select_drag", %{"ids" => ["1", "2", "3"], "mode" => "select"})
    render_hook(view, "select_drag", %{"ids" => ["2"], "mode" => "deselect"})

    assert render(view) =~ "2 selected"
    assert checked?(view, 1)
    refute checked?(view, 2)
    assert checked?(view, 3)
  end

  test "select_drag is additive over a prior single-click selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_click(view, "toggle_select", %{"id" => "1"})
    render_hook(view, "select_drag", %{"ids" => ["2", "3"], "mode" => "select"})

    assert render(view) =~ "3 selected"
  end

  test "re-selecting already-selected ids keeps the count stable (idempotent)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_hook(view, "select_drag", %{"ids" => ["1", "2"], "mode" => "select"})
    render_hook(view, "select_drag", %{"ids" => ["1", "2"], "mode" => "select"})

    assert render(view) =~ "2 selected"
  end

  test "non-numeric and empty ids are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_hook(view, "select_drag", %{"ids" => ["x", "nope"], "mode" => "select"})
    refute checked?(view, 1) or checked?(view, 2) or checked?(view, 3)

    render_hook(view, "select_drag", %{"ids" => [], "mode" => "select"})
    refute checked?(view, 1) or checked?(view, 2) or checked?(view, 3)
  end

  test "a drag selection feeds the existing bulk actions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    seed_rows(view)

    render_hook(view, "select_drag", %{"ids" => ["1", "2"], "mode" => "select"})
    html = render(view)
    assert html =~ "2 selected"
    assert html =~ "EXPLAIN"
    assert html =~ "HIDE"
  end

  defp wait_render(view, substring, attempts \\ 150) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end
end
