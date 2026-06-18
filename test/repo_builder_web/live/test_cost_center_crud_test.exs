defmodule RepoBuilderWeb.TestCostCenterCrudTest do
  @moduledoc """
  Integration test for the Cost Center price-catalog CRUD surface (issue-cost-center-crud):
  per-row Edit loads the row into the form with its identity key locked (readonly), Cancel
  resets to create mode, an edit submit updates the same row in place without creating a
  duplicate, and the Delete control carries a `data-confirm` confirmation.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.CostCenter

  defp open_cost_center(view) do
    render_click(view, "select_settings_tab", %{"tab" => "cost_center"})
  end

  test "edit loads + locks the row, save updates in place, cancel + delete-confirm work", %{
    conn: conn
  } do
    {:ok, price} =
      CostCenter.upsert_price(%{
        harness: "pi",
        provider: "zai",
        model: "glm-4.6",
        input_price_per_mtok: "0.6",
        output_price_per_mtok: "2.0"
      })

    {:ok, view, _html} = live(conn, "/")
    open_cost_center(view)

    # Clicking Edit loads the row: an "Editing" header + readonly identity inputs + Cancel.
    edit_html = render_click(view, "edit_price", %{"id" => price.id})
    assert edit_html =~ "Editing"
    assert has_element?(view, "#price-cancel")
    assert has_element?(view, "#price-form input[name=\"model_price[harness]\"][readonly]")
    assert has_element?(view, "#price-form input[name=\"model_price[model]\"][readonly]")

    # Submitting an edit (changing only the output rate) updates the SAME row in place.
    count_before = length(CostCenter.list_prices())

    view
    |> form("#price-form", %{"model_price" => %{"output_price_per_mtok" => "9.0"}})
    |> render_submit()

    updated = CostCenter.get_price(price.id)
    assert updated.id == price.id
    assert Decimal.equal?(updated.output_price_per_mtok, Decimal.new("9.0"))
    assert updated.source == :manual
    # No duplicate row was created.
    assert length(CostCenter.list_prices()) == count_before
    # Back in create mode after a successful save.
    refute render(view) =~ "Editing"

    # Re-enter edit mode, then Cancel returns to create mode.
    render_click(view, "edit_price", %{"id" => price.id})
    assert render(view) =~ "Editing"
    cancel_html = render_click(view, "cancel_edit", %{})
    refute cancel_html =~ "Editing"

    # The Delete control carries a data-confirm guard.
    assert has_element?(view, "#price-delete-#{price.id}[data-confirm]")
  end
end
