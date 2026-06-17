defmodule RepoBuilderWeb.TestOrchestratorReasoningEffortTest do
  @moduledoc """
  Integration test for the harness-blind "Reasoning effort" control in the General
  settings tab (see
  specs/issue-spec-adw-this-sdlc_planner-unified-reasoning-effort.md).

  Drives the segmented control and asserts the chosen level persists to the default
  orchestrator row and reflects in the DOM. Single control, no per-harness tabs.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  `fake` harness (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  test "the reasoning-effort control persists the chosen level", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The control renders in the (default) General tab; :default is active.
    assert has_element?(view, "#settings-reasoning-effort")
    assert has_element?(view, "#settings-reasoning-effort-default.cns-toggle__seg--active")

    # Pick HIGH → persisted on the row and reflected as the active segment.
    view |> element("#settings-reasoning-effort-high") |> render_click()

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.reasoning_effort == :high
    assert has_element?(view, "#settings-reasoning-effort-high.cns-toggle__seg--active")

    # MAX maps through too.
    view |> element("#settings-reasoning-effort-max") |> render_click()
    assert {:ok, %{reasoning_effort: :max}} = Orchestrators.get_or_create_default()

    # Back to DEFAULT clears the flag intent.
    view |> element("#settings-reasoning-effort-default") |> render_click()
    {:ok, reset} = Orchestrators.get_or_create_default()
    assert reset.reasoning_effort == :default
    assert has_element?(view, "#settings-reasoning-effort-default.cns-toggle__seg--active")
  end
end
