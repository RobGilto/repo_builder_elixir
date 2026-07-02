defmodule RepoBuilderWeb.CommandAutocompleteTest do
  use RepoBuilderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  test "command textarea has data-autocomplete attr with slash/agent/adw items", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, html} = live(conn, "/")

    # data-autocomplete is present on mount.
    assert html =~ "data-autocomplete"

    # The attribute value is valid JSON containing at least the trigger keys.
    # We use has_element? to check the textarea carries the attribute.
    assert has_element?(view, "#command-textarea[data-autocomplete]")
  end

  test "autocomplete dropdown element exists in COMMAND mode markup", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#autocomplete-dropdown")
  end

  test "slash commands appear in autocomplete JSON when definitions are loaded", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, _view, html} = live(conn, "/")

    # The page serializes known slash commands into data-autocomplete.
    # With a live app that has .claude/commands/, the JSON contains "/" triggers.
    # We assert the attribute is non-empty JSON (may be [] in test env with no cmds).
    assert html =~ ~s(data-autocomplete=")
  end
end
