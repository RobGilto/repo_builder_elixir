defmodule RepoBuilderWeb.StackLayersSettingsTest do
  @moduledoc """
  Integration test for the Stack Layers catalog CRUD surface (stack-layers subsystem) on
  the Settings → Stack Layers tab: create a layer via the form, see it persist + render,
  per-row Edit loads it into the form, an edit submit updates in place, Cancel resets, and
  Delete carries a `data-confirm` guard.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.StackLayers

  defp open_tab(view), do: render_click(view, "select_settings_tab", %{"tab" => "stack_layers"})

  test "create, edit-in-place, cancel, and delete a layer via the settings tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open_tab(view)
    assert has_element?(view, "#stack-layer-form")

    # Create a layer.
    view
    |> form("#stack-layer-form", %{
      "stack_layer" => %{
        "layer_type" => "backend",
        "name" => "Phoenix",
        "language" => "elixir",
        "reasoning" => "typed contexts only"
      }
    })
    |> render_submit()

    layer = Enum.find(StackLayers.list_layers(), &(&1.name == "Phoenix"))
    assert layer
    assert layer.layer_type == :backend
    assert layer.source == :manual
    assert has_element?(view, "#stack-layer-row-#{layer.id}")

    # Edit loads the row into the form.
    edit_html = render_click(view, "edit_layer", %{"id" => layer.id})
    assert edit_html =~ "Editing"
    assert has_element?(view, "#stack-layer-cancel")

    # Edit submit updates the same row in place (no duplicate).
    count_before = length(StackLayers.list_layers())

    view
    |> form("#stack-layer-form", %{"stack_layer" => %{"language" => "elixir-1.20"}})
    |> render_submit()

    updated = StackLayers.get_layer(layer.id)
    assert updated.language == "elixir-1.20"
    assert length(StackLayers.list_layers()) == count_before
    refute render(view) =~ "Editing"

    # Cancel returns to create mode.
    render_click(view, "edit_layer", %{"id" => layer.id})
    assert render(view) =~ "Editing"
    refute render_click(view, "cancel_layer_edit", %{}) =~ "Editing"

    # Delete carries a confirm guard and removes the row.
    assert has_element?(view, "#stack-layer-delete-#{layer.id}[data-confirm]")
    render_click(view, "delete_layer", %{"id" => layer.id})
    assert StackLayers.get_layer(layer.id) == nil
    refute has_element?(view, "#stack-layer-row-#{layer.id}")
  end
end
