defmodule RepoBuilderWeb.TestExplainLogsTest do
  @moduledoc """
  LiveView integration for the ephemeral explain-logs aid (issue-explain): select a
  center event-stream row, press EXPLAIN, and the configured Fast agent (the keyless
  Fake harness, for determinism) returns a one-paragraph gloss in a transient modal —
  with NOTHING persisted (no `agent_logs` row for the ephemeral agent, no global feed
  event) and a Copy button carrying the result.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  test "select → EXPLAIN → ephemeral Fast-agent result modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # The default orchestrator's Fast tier points at the keyless Fake harness.
    {:ok, orch} = Orchestrators.get_or_create_default()

    {:ok, _} =
      Orchestrators.set_agent_model(orch.id, "fast", %{
        "harness" => "fake",
        "provider" => "",
        "model" => "fake-model-1"
      })

    # Seed a couple of rows into the center stream (deterministic ToolCall events).
    Dashboard.broadcast_event("worker-a", tool_call("call_1", "bash"), 11)
    Dashboard.broadcast_event("worker-a", tool_call("call_2", "edit"), 12)

    assert wait_render(view, "log-11")

    # Select the first row (id is the per-socket seq counter; first recorded ⇒ 1).
    render_click(view, "toggle_select", %{"id" => "1"})

    # The selection bar appears with the EXPLAIN action.
    html = render(view)
    assert html =~ "1 selected"
    assert html =~ "EXPLAIN"

    # Press EXPLAIN — the modal flips to its running state immediately.
    html = render_click(view, "explain_selected", %{})
    assert html =~ "Explaining 1 event(s)"

    # The Fake Fast agent finishes; the paragraph renders with a Copy button.
    assert wait_render(view, "Hello world")
    assert render(view) =~ ~s(data-copy="Hello world")

    # Nothing persisted: no agent_logs row references the ephemeral explain agent.
    drain_sessions()
    refute Enum.any?(Logs.list_recent_global(500, true), &explain_row?/1)
  end

  test "no Fast agent configured shows an actionable error and starts no run", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Default orchestrator has no Fast tier set — leave it unconfigured.
    Dashboard.broadcast_event("worker-a", tool_call("call_1", "bash"), 21)
    assert wait_render(view, "log-21")

    render_click(view, "toggle_select", %{"id" => "1"})
    html = render_click(view, "explain_selected", %{})

    assert html =~ "No Fast agent configured"
    assert %{active: 0} = DynamicSupervisor.count_children(RepoBuilder.ExplainSupervisor)
  end

  defp tool_call(id, name) do
    %Event.ToolCall{harness: :fake, id: id, name: name, input: %{"cmd" => "echo hi"}}
  end

  defp explain_row?(%{session_id: session_id}) when is_binary(session_id),
    do: String.starts_with?(session_id, "explain-")

  defp explain_row?(_log), do: false

  defp drain_sessions(attempts \\ 150) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp wait_render(view, substring, attempts \\ 150) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end
end
