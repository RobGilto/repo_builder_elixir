defmodule RepoBuilderWeb.TestAdwsStageSwimlanesTest do
  @moduledoc """
  Stage-based ADW swimlanes (issue stage-based-adw-swimlanes): a recorded neutral ADW
  stdout stream is replayed through the REAL adapter (`RepoBuilder.Harness.Adw.normalize/2`)
  and broadcast onto the console feed, exactly as the §6 runtime drives it. The ADWS view
  must group each agent's events into per-stage lanes (`plan` → `build` → `review`) in
  first-appearance order, bucket events with no `adw_step` under a single "Workflow" lane,
  and surface the stage in the click-to-open detail panel.

  `async: false` (shared Ecto sandbox), mirroring the other console tests.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Adw

  @adw_ctx %{harness: :adw, model: "claude-sonnet-4-6", price_table: %{}}

  # A recorded neutral ADW stdout stream: a `session_started` with NO `adw_step` (⇒ the
  # "Workflow" fallback lane), then plan → build → review frames each tagged with their
  # stage.
  @frames [
    %{
      "schema_version" => 1,
      "type" => "session_started",
      "adw_id" => "adw-stage",
      "model" => "claude-sonnet-4-6"
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-stage",
      "adw_step" => "plan",
      "index" => 1,
      "total" => 3
    },
    %{
      "schema_version" => 1,
      "type" => "text",
      "adw_id" => "adw-stage",
      "adw_step" => "plan",
      "text" => "planning the work"
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-stage",
      "adw_step" => "build",
      "index" => 2,
      "total" => 3
    },
    %{
      "schema_version" => 1,
      "type" => "text",
      "adw_id" => "adw-stage",
      "adw_step" => "build",
      "text" => "building the work"
    },
    %{
      "schema_version" => 1,
      "type" => "step_start",
      "adw_id" => "adw-stage",
      "adw_step" => "review",
      "index" => 3,
      "total" => 3
    }
  ]

  # Replay the recorded stdout through the REAL adapter, broadcasting each canonical event
  # onto the console feed exactly as the §6 runtime would.
  @spec replay(String.t()) :: :ok
  defp replay(agent_id) do
    Enum.each(@frames, fn frame ->
      case Adw.normalize(frame, @adw_ctx) do
        {:ok, events} -> Enum.each(events, &Dashboard.broadcast_event(agent_id, &1))
        _ -> :ok
      end
    end)
  end

  @spec index!(binary(), binary()) :: non_neg_integer()
  defp index!(html, needle) do
    case :binary.match(html, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("expected the console to render #{inspect(needle)}")
    end
  end

  test "ADW events render as per-stage lanes in first-appearance order", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    replay("orch-adw-#{System.unique_integer([:positive])}")

    html = render(view)

    # The stage-lane labels render as humanized `.cns-step-box__name` spans, in
    # first-appearance order: the no-step session event first ("Workflow"), then
    # plan → build → review.
    workflow = index!(html, ">Workflow</span>")
    plan = index!(html, ">Plan</span>")
    build = index!(html, ">Build</span>")
    review = index!(html, ">Review</span>")

    assert workflow < plan
    assert plan < build
    assert build < review

    # Each lane carries a stable id so its squares group under the right stage.
    assert html =~ ~r/id="swimlane-orch-adw-\d+-stage-plan"/
    assert html =~ ~r/id="swimlane-orch-adw-\d+-stage-_workflow"/

    # Squares (clickable event faces) render inside the lanes.
    assert html =~ "cns-square"
  end

  test "clicking a square opens the detail panel showing the event's stage", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    replay("orch-adw-#{System.unique_integer([:positive])}")

    html = render(view)

    # The first rendered square belongs to the no-step session event ⇒ "Workflow" stage.
    [_, square_id] = Regex.run(~r/id="square-(\d+)"/, html)

    view
    |> element("#square-#{square_id}")
    |> render_click()

    # The detail panel is open and its metadata grid now shows the event's stage
    # (the no-step session event humanizes to "Workflow").
    panel = view |> element("#event-detail-panel") |> render()
    assert panel =~ "step"
    assert panel =~ "Workflow"
  end
end
