defmodule RepoBuilderWeb.TestFileDiffEventCardsTest do
  @moduledoc """
  LiveView integration test for the file-diff event cards feature
  (issue file-diff-event-cards).

  Drives `Write` and `Edit` tool-call events through the console's
  `{:agent_event, agent_id, %Event.ToolCall{}, log_no}` seam and asserts:
  - The rendered row shows the correct status badge and +N/-N stats.
  - Expanding the row shows colored diff lines (cns-diff__line--add / --del).
  - The Open button renders with `phx-value-path` for absolute paths.
  - Clicking Open triggers the `open_file` handler; with the editor disabled in tests it
    flashes a clear error without crashing the LiveView.

  Uses `async: false` for the shared Ecto sandbox + console LiveView.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.Event

  defp uniq_name, do: "diff-agent-#{System.unique_integer([:positive])}"

  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  describe "Write tool-call event" do
    test "renders a Created badge and +N stats in the event row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Write",
        input: %{
          "file_path" => "/abs/path/new_file.ex",
          "content" => "defmodule Foo do\n  :ok\nend"
        }
      })

      assert wait_until(fn ->
               html = render(view)
               html =~ "✓ Created" and html =~ "+3"
             end)

      html = render(view)
      assert html =~ "✓ Created"
      assert html =~ "+3"
      assert html =~ "-0"
    end

    test "renders the file path in the card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Write",
        input: %{
          "file_path" => "/workspace/myapp/lib/myapp.ex",
          "content" => "hello"
        }
      })

      assert wait_until(fn ->
               render(view) =~ "/workspace/myapp/lib/myapp.ex"
             end)
    end

    test "shows the Open button for absolute paths", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Write",
        input: %{
          "file_path" => "/abs/file.ex",
          "content" => "x"
        }
      })

      assert wait_until(fn ->
               html = render(view)
               html =~ "phx-value-path=\"/abs/file.ex\""
             end)
    end

    test "clicking Open flashes an error when editor is disabled (no crash)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      # Write a real tmp file so the path validation passes (path must exist for Editor.open/1
      # to reach the disabled check... actually disabled check is first, so any path works).
      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Write",
        input: %{"file_path" => "/abs/open_test.ex", "content" => "hello"}
      })

      assert wait_until(fn -> render(view) =~ "phx-value-path" end)

      # Click the Open button: editor is disabled in test config → error flash.
      view
      |> element("[phx-click='open_file'][phx-value-path='/abs/open_test.ex']")
      |> render_click()

      # The LiveView must not crash and must display an error flash.
      assert render(view) =~ "disabled"
    end
  end

  describe "Edit tool-call event" do
    test "renders a Modified badge and correct +N/-N stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Edit",
        input: %{
          "file_path" => "/app/foo.ex",
          "old_string" => "old line\nshared line",
          "new_string" => "new line\nshared line"
        }
      })

      assert wait_until(fn ->
               html = render(view)
               html =~ "✎ Modified" and html =~ "+1"
             end)

      html = render(view)
      assert html =~ "✎ Modified"
      assert html =~ "/app/foo.ex"
    end

    test "expanded row shows colored diff lines", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Edit",
        input: %{
          "file_path" => "/app/bar.ex",
          "old_string" => "removed line",
          "new_string" => "added line"
        }
      })

      assert wait_until(fn ->
               render(view) =~ "✎ Modified"
             end)

      # Expand the row by clicking it (toggle_event fires on the row div).
      # Find the event row that contains our file and expand it.
      html_before_expand = render(view)

      # The cns-diff lines are only rendered when expanded — assert they're absent
      # before expansion.
      refute html_before_expand =~ "cns-diff__line--add"

      # Click the event row to expand it. The row id is the seq number; we look for
      # the row that has our path and expand it.
      view
      |> element("[phx-click='toggle_event']", "")
      |> render_click()

      html_after = render(view)
      # After expansion, the diff lines should be present.
      assert html_after =~ "cns-diff__line"
    end
  end

  describe "non-file tool events" do
    test "Bash tool renders the generic card (no file badge)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent = create_agent(view, uniq_name())

      Dashboard.broadcast_event(agent.id, %Event.ToolCall{
        harness: :fake,
        name: "Bash",
        input: %{"command" => "echo hello"}
      })

      assert wait_until(fn -> render(view) =~ "Using tool: Bash" end)
      html = render(view)
      # Generic tool card, no file badge.
      refute html =~ "✓ Created"
      refute html =~ "✎ Modified"
    end
  end
end
