defmodule RepoBuilderWeb.TestStreamingConsoleTest do
  @moduledoc """
  Integration test for harness-blind token-by-token streaming in the console
  (BUILD_PROMPT.md §9, streaming feature). For BOTH the `:claude` and `:pi`
  harnesses it asserts:

    * partials coalesce into ONE growing streaming bubble (no per-token fragments),
    * a finalized `partial?: false` block finalizes to exactly one message and the
      live bubble disappears (no duplicate),
    * the thinking channel coalesces independently and respects `@show_thinking?`,
    * a partial-only stream ending in `Done` still promotes the buffered text once.

  Events are pushed onto the global `console:events` feed via
  `Dashboard.broadcast_event/2`; the ~50 ms flush tick is driven deterministically
  by sending `:flush_stream` to the view (no `Process.sleep`). `async: false`
  matches the other console tests (shared Ecto sandbox).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  # Flush the throttled streaming buffer deterministically, then drain the mailbox.
  defp flush(view) do
    send(view.pid, :flush_stream)
    render(view)
  end

  # `element/2` raises if the selector matches more than one node, so a successful
  # render asserts EXACTLY one matching element — our "no duplicate" guarantee.
  defp assert_single(view, selector) do
    assert view |> element(selector) |> render()
  end

  for harness <- [:claude, :pi] do
    @harness harness

    test "[#{harness}] partials coalesce into one growing bubble, finalize once, no duplicate",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent_id = "stream-#{System.unique_integer([:positive])}"

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "Hel",
        partial?: true
      })

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "lo",
        partial?: true
      })

      _ = flush(view)

      # One growing streaming bubble containing the coalesced text — not two fragments.
      assert has_element?(view, "#streaming-text-#{agent_id}", "Hello")
      assert_single(view, ".cns-bubble--streaming")

      # The authoritative finalized block arrives.
      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "Hello",
        partial?: false
      })

      _ = render(view)

      # The live bubble is gone and exactly one finalized orchestrator message remains.
      refute has_element?(view, "#streaming-text-#{agent_id}")
      refute has_element?(view, ".cns-bubble--streaming")
      assert has_element?(view, ".cns-bubble--orch", "Hello")
      assert_single(view, ".cns-bubble--orch")
    end

    test "[#{harness}] the thinking channel coalesces independently and respects @show_thinking?",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent_id = "stream-think-#{System.unique_integer([:positive])}"

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "pon",
        thinking?: true,
        partial?: true
      })

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "dering",
        thinking?: true,
        partial?: true
      })

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "answer",
        thinking?: false,
        partial?: true
      })

      _ = flush(view)

      # Text and thinking grow in separate bubbles (no cross-contamination).
      assert has_element?(view, "#streaming-think-#{agent_id}", "pondering")
      assert has_element?(view, "#streaming-text-#{agent_id}", "answer")

      # Hiding thinking drops the thinking bubble but keeps the text bubble.
      view |> element("#settings-thinking") |> render_click()
      refute has_element?(view, "#streaming-think-#{agent_id}")
      assert has_element?(view, "#streaming-text-#{agent_id}", "answer")
    end

    test "[#{harness}] a partial-only stream ending in Done promotes the buffer once",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      agent_id = "stream-done-#{System.unique_integer([:positive])}"

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "only ",
        partial?: true
      })

      Dashboard.broadcast_event(agent_id, %Event.TextDelta{
        harness: @harness,
        text: "partials",
        partial?: true
      })

      _ = flush(view)
      assert has_element?(view, "#streaming-text-#{agent_id}", "only partials")

      # No finalized block — Done flushes the leftover buffer to one message.
      Dashboard.broadcast_event(agent_id, %Event.Done{
        harness: @harness,
        ok: true,
        reason: :agent_end
      })

      _ = render(view)

      refute has_element?(view, "#streaming-text-#{agent_id}")
      assert has_element?(view, ".cns-bubble--orch", "only partials")
      assert_single(view, ".cns-bubble--orch")
    end
  end
end
