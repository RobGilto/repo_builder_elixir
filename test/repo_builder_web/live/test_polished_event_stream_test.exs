defmodule RepoBuilderWeb.TestPolishedEventStreamTest do
  @moduledoc """
  LiveView integration for the polished structured event-stream cards
  (issue polished-event-stream-cards): driving a tool call, a tool result, and a
  response-with-file-activity through the live PubSub event seam renders the structured
  card (`Using tool: …`, tool pill, clean preview, "Consumed N files") — NOT a raw
  `inspect` map dump — and expanding a row reveals the full detail.

  Uses the same `Dashboard.broadcast_event/3` seam the runtime uses; `async: false`
  because the console subscribes to the shared global feed.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  defp wait_render(view, substring, attempts \\ 150) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end

  test "tool call renders a structured card, not a raw inspect dump", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Dashboard.broadcast_event(
      "worker-a",
      %Event.ToolCall{harness: :fake, name: "Bash", input: %{"command" => "echo hi"}},
      101
    )

    assert wait_render(view, "Using tool: Bash")
    html = render(view)
    # Clean summary + content preview, and a tool pill...
    assert html =~ "Using tool: Bash"
    assert html =~ "command: echo hi"
    assert html =~ "cns-tool-pill"
    # ...with no raw Elixir-map inspect dump in the row.
    refute html =~ ~s(%{"command")
  end

  test "tool result renders a clean preview and a consumed-files card", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    content = %{
      "content" => [%{"type" => "text", "text" => "read 2 files successfully"}],
      "files" => [
        %{"path" => "/lib/a.ex", "action" => "read", "bytes" => 1200},
        %{"path" => "/lib/b.ex", "action" => "read", "bytes" => 88}
      ]
    }

    Dashboard.broadcast_event(
      "worker-a",
      %Event.ToolResult{harness: :fake, is_error: false, content: content},
      102
    )

    assert wait_render(view, "Tool result")
    html = render(view)
    assert html =~ "read 2 files successfully"
    assert html =~ "Consumed 2 files"
    assert html =~ "/lib/a.ex"
    assert html =~ "1.2 KB"
    # No double-escaped wire JSON for the content envelope.
    refute html =~ ~s(%{"isError")
    refute html =~ ~s("type" => "text")
  end

  test "error tool result gets the red error accent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Dashboard.broadcast_event(
      "worker-a",
      %Event.ToolResult{harness: :fake, is_error: true, content: "command failed"},
      103
    )

    assert wait_render(view, "Tool result")
    assert render(view) =~ "cns-event-card--error"
  end

  test "response with file activity renders the Consumed card", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Dashboard.broadcast_event(
      "worker-a",
      %Event.TextDelta{
        harness: :fake,
        text: "Done reading the project.",
        raw: %{"files" => [%{"path" => "/mix.exs", "action" => "read", "bytes" => 640}]}
      },
      104
    )

    assert wait_render(view, "Done reading the project.")
    html = render(view)
    assert html =~ "Consumed 1 file"
    assert html =~ "/mix.exs"
  end

  test "expanding a row reveals the full detail", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Long body: the END marker sits beyond the collapsed preview clamp, so it only
    # appears once the row is expanded.
    long = "START of output\n" <> String.duplicate("x", 400) <> "\nEND_MARKER_42"

    Dashboard.broadcast_event(
      "worker-a",
      %Event.ToolResult{harness: :fake, is_error: false, content: long},
      105
    )

    assert wait_render(view, "START of output")
    # Collapsed: the trailing marker is truncated out of the row's preview block.
    refute render(element(view, "#ev-row-1")) =~ "END_MARKER_42"

    render_click(view, "toggle_event", %{"id" => "1"})
    assert render(element(view, "#ev-row-1")) =~ "END_MARKER_42"
  end
end
