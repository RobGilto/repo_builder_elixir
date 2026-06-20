defmodule RepoBuilderWeb.TestOrchestratorAdwShelloutTest do
  @moduledoc """
  End-to-end proof of the ADW canonical-event bridge (issue-the-adw-gap): a recorded
  neutral stdout-JSON stream (exactly what a portable Python ADW prints in `--emit
  json` mode) is decoded through `RepoBuilder.Harness.Adw.normalize/2` into canonical
  events and broadcast onto the console feed — the same path the live §6 session
  runtime drives. The console then shows ordered per-step progress (plan→build→review)
  and the accumulated cost, proving the shell-out harness reaches the unified console
  with no second system of record.

  `async: false` (shared Ecto sandbox), mirroring the other console tests.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Adw

  @adw_ctx %{harness: :adw, model: "claude-sonnet-4-6", price_table: %{}}

  # A recorded neutral ADW stdout stream for a plan→build→review run.
  @frames [
    %{
      "schema_version" => 1,
      "type" => "session_started",
      "adw_id" => "adw-1",
      "model" => "claude-sonnet-4-6"
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-1",
      "adw_step" => "plan",
      "index" => 1,
      "total" => 3
    },
    %{
      "schema_version" => 1,
      "type" => "text",
      "adw_id" => "adw-1",
      "adw_step" => "plan",
      "text" => "planning the work"
    },
    %{
      "schema_version" => 1,
      "type" => "usage",
      "adw_id" => "adw-1",
      "adw_step" => "plan",
      "input_tokens" => 100,
      "output_tokens" => 50,
      "cost_usd" => 0.01
    },
    %{
      "schema_version" => 1,
      "type" => "step_end",
      "adw_id" => "adw-1",
      "adw_step" => "plan",
      "status" => "succeeded",
      "cost_usd" => 0.01
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-1",
      "adw_step" => "build",
      "index" => 2,
      "total" => 3
    },
    %{
      "schema_version" => 1,
      "type" => "usage",
      "adw_id" => "adw-1",
      "adw_step" => "build",
      "input_tokens" => 200,
      "output_tokens" => 80,
      "cost_usd" => 0.02
    },
    %{
      "schema_version" => 1,
      "type" => "step_end",
      "adw_id" => "adw-1",
      "adw_step" => "build",
      "status" => "succeeded",
      "cost_usd" => 0.02
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-1",
      "adw_step" => "review",
      "index" => 3,
      "total" => 3
    },
    %{
      "schema_version" => 1,
      "type" => "step_end",
      "adw_id" => "adw-1",
      "adw_step" => "review",
      "status" => "succeeded",
      "cost_usd" => 0.0
    },
    %{
      "schema_version" => 1,
      "type" => "done",
      "adw_id" => "adw-1",
      "ok" => true,
      "reason" => "success",
      "final_text" => "shipped"
    }
  ]

  # Replay the recorded stdout through the REAL adapter (normalize/2), broadcasting each
  # canonical event onto the console feed exactly as the §6 runtime would.
  defp replay(agent_id) do
    Enum.each(@frames, fn frame ->
      case Adw.normalize(frame, @adw_ctx) do
        {:ok, events} -> Enum.each(events, &Dashboard.broadcast_event(agent_id, &1))
        _ -> :ok
      end
    end)
  end

  defp index!(html, needle) do
    case :binary.match(html, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("expected the console to render #{inspect(needle)}")
    end
  end

  test "a recorded ADW stdout stream renders ordered per-step progress + cost in the console",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    replay("orch-adw-#{System.unique_integer([:positive])}")

    html = render(view)

    # Ordered per-step progress: each step's tool-call card renders the polished
    # `Using tool: <step>` summary (issue polished-event-stream-cards) in order. This
    # targets the event-stream tool card, not the ADWS palette chips (whose tokens are
    # `plan_build` etc., never `Using tool: plan`).
    plan = index!(html, "Using tool: plan")
    build = index!(html, "Using tool: build")
    review = index!(html, "Using tool: review")
    assert plan < build
    assert build < review

    # Accumulated cost from the canonical usage events (0.01 + 0.02 = 0.03).
    assert html =~ "$0.03"
  end

  test "an unknown/older-schema line in the stream is tolerated (no crash, others still render)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent_id = "orch-adw-#{System.unique_integer([:positive])}"

    # A garbled + a future-schema frame interleaved with a real one.
    [
      %{"type" => "totally_unknown", "adw_step" => "plan"},
      %{"schema_version" => 999, "type" => "text", "text" => "from the future"},
      %{
        "schema_version" => 1,
        "type" => "step_start",
        "adw_id" => agent_id,
        "adw_step" => "buildit",
        "index" => 1,
        "total" => 1
      }
    ]
    |> Enum.each(fn frame ->
      case Adw.normalize(frame, @adw_ctx) do
        {:ok, events} -> Enum.each(events, &Dashboard.broadcast_event(agent_id, &1))
        _ -> :ok
      end
    end)

    html = render(view)
    assert html =~ "buildit"
    refute html =~ "from the future"
  end
end
