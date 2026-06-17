defmodule RepoBuilderWeb.TestOrchestratorSystemPromptTest do
  @moduledoc """
  Integration test for the "System Prompt" settings tab (see
  specs/issue-sysprompt-adw-f3a1c7e2-sdlc_planner-orchestrator-system-prompt-settings.md).

  Opens the tab, asserts the textarea + generated-default preview render, saves a
  custom prompt + replace mode, and resets back to the generated default — verifying
  the persisted `orchestrators` row at each step via the `Orchestrators` context.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  `fake` harness (registered in `config/test.exs`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  test "the System Prompt tab edits, saves, and resets the orchestrator prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Open the System Prompt tab; the textarea + generated-default preview render.
    view |> element("button[phx-value-tab=prompt]") |> render_click()
    assert has_element?(view, "#settings-system-prompt")
    assert has_element?(view, "#settings-system-prompt-default")
    assert has_element?(view, "#settings-system-prompt-mode-append.cns-toggle__seg--active")

    # Save a custom prompt in replace mode.
    view
    |> form("#settings-system-prompt-form")
    |> render_submit(%{"system_prompt" => "Be terse.", "mode" => "replace"})

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.system_prompt == "Be terse."
    assert orch.system_prompt_mode == :replace

    # The replace segment is now the active mode in the DOM.
    assert has_element?(view, "#settings-system-prompt-mode-replace.cns-toggle__seg--active")
    assert has_element?(view, "#settings-system-prompt", "Be terse.")

    # Reset clears the override and restores :append; the textarea renders empty.
    view |> element("#settings-system-prompt-reset") |> render_click()

    {:ok, reset} = Orchestrators.get_or_create_default()
    assert reset.system_prompt == nil
    assert reset.system_prompt_mode == :append
    assert has_element?(view, "#settings-system-prompt-mode-append.cns-toggle__seg--active")
    refute has_element?(view, "#settings-system-prompt", "Be terse.")
  end

  test "the mode toggle persists the chosen mode immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-value-tab=prompt]") |> render_click()

    view |> element("#settings-system-prompt-mode-replace") |> render_click()

    {:ok, orch} = Orchestrators.get_or_create_default()
    assert orch.system_prompt_mode == :replace
  end
end
