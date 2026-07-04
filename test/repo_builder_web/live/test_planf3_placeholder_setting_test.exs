defmodule RepoBuilderWeb.TestPlanf3PlaceholderSettingTest do
  @moduledoc """
  Integration test for the "Plan images: use placeholders" toggle on the Settings →
  General tab (spec planf3-html-plans-for-heavy-adw-planner, Phase 5): ticked ON by
  default with no persisted row, untick persists the flipped setting and surfaces the
  missing-key warning while no `OPENAI_API_KEY` secret exists in either vault scope,
  and re-ticking persists back and hides the warning.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Settings

  test "defaults ON, untick persists + warns without a key, re-tick restores",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Default: ticked ON with no persisted row; no warning rendered.
    assert Settings.planf3_image_placeholders?()
    assert view |> element("#settings-planf3-placeholders") |> render() =~ "ON"
    refute has_element?(view, "#settings-planf3-key-warning")

    # Untick: persists false and (no OPENAI_API_KEY secret in any scope) warns.
    view |> element("#settings-planf3-placeholders") |> render_click()
    refute Settings.planf3_image_placeholders?()
    assert view |> element("#settings-planf3-placeholders") |> render() =~ "OFF"
    assert has_element?(view, "#settings-planf3-key-warning")

    # Re-tick: persists true again and the warning disappears.
    view |> element("#settings-planf3-placeholders") |> render_click()
    assert Settings.planf3_image_placeholders?()
    refute has_element?(view, "#settings-planf3-key-warning")
  end
end
