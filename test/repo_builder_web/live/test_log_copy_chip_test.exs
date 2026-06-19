defmodule RepoBuilderWeb.TestLogCopyChipTest do
  @moduledoc """
  Integration test for the fixed-width log-number chip with click-to-copy /
  drag-to-copy-range (see
  specs/issue-chip-adw-with-sdlc_planner-log-number-copy-chip.md).

  The copy/drag interaction itself is browser-only (clipboard + pointer geometry)
  and lives in the `LogCopy` JS hook, so it is NOT exercised here. This test pins
  the SERVER-RENDERED contract that hook depends on:

    * each event row's log-number span carries the `cns-event-row__ln` class,
    * a real `log_no` is stamped on `data-log="log-<n>"` (the hook's copy source),
    * a `nil` `log_no` row (the `@line` fallback) omits `data-log` entirely, and
    * the `#event-stream-wrap` stream host is present.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  test "a real log_no row stamps data-log and the stream host is present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    event = %Event.ToolCall{harness: :fake, name: "read_file", input: %{"path" => "x"}}
    Dashboard.broadcast_event("worker-copy", event, 4242)
    _ = render(view)

    # The hook host wrapper that owns the live stream.
    assert has_element?(view, "#event-stream-wrap")
    # The full value rides on data-log so the truncated display never loses it.
    assert has_element?(view, "span.cns-event-row__ln[data-log='log-4242']")
    # ...and is also exposed via title for hover.
    assert has_element?(view, "span.cns-event-row__ln[title='log-4242']")
  end

  test "a nil log_no row falls back to the line number and omits data-log", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    event = %Event.ToolCall{harness: :fake, name: "read_file", input: %{"path" => "y"}}
    # No log_no → the span shows the @line fallback and must NOT carry data-log,
    # so the hook treats the row as non-copyable.
    Dashboard.broadcast_event("worker-nolog", event)
    _ = render(view)

    assert has_element?(view, "span.cns-event-row__ln:not([data-log])")
  end
end
