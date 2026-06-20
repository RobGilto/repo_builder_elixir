defmodule RepoBuilderWeb.TestBudgetGuardrailsTest do
  @moduledoc """
  Integration test for the budget guardrails console surface (issue-budget-guardrails):
  the panel CRUD form, the tripped/kill-switch banner, the budget badge, and the
  kill-switch button — driven over the `"budget:events"` topic and the in-memory
  `Budget.Guard` kill switch.

  `async: false` because it engages the shared global `Budget.Guard` kill switch; it is
  always released in `on_exit/1` so it cannot leak into another test.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Budget

  setup do
    on_exit(fn -> Budget.Guard.release_all() end)
    :ok
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  test "create a cap, then engage/release the kill switch live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The badge and panel render on the connected mount.
    assert has_element?(view, "#budget-badge")
    assert has_element?(view, "#budget-panel")
    assert has_element?(view, "#kill-switch")

    # Create a small global :pause cap through the panel form.
    view
    |> element("#budget-form")
    |> render_submit(%{
      "budget" => %{
        "scope" => "global",
        "scope_id" => "",
        "period" => "total",
        "limit_usd" => "5.0",
        "action" => "pause"
      }
    })

    assert render(view) =~ "Global"
    assert [%{scope: :global}] = Budget.list_caps()

    # Engage the kill switch: the banner appears and the badge flips to the tripped state.
    view |> element("#kill-switch") |> render_click()

    assert wait_until(fn -> has_element?(view, "#budget-banner") end)
    assert has_element?(view, ~s(#budget-badge[data-budget-state="tripped"]))
    assert has_element?(view, ~s(#kill-switch[data-engaged="true"]))

    # Release it: the banner clears and the badge returns to ok.
    view |> element("#kill-switch") |> render_click()

    assert wait_until(fn -> not has_element?(view, "#budget-banner") end)
    assert has_element?(view, ~s(#kill-switch[data-engaged="false"]))
  end

  test "every visible cap is editable in place, and editing upserts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#budget-form")
    |> render_submit(%{
      "budget" => %{
        "scope" => "global",
        "scope_id" => "",
        "period" => "total",
        "limit_usd" => "5.0",
        "action" => "alert"
      }
    })

    assert [%{id: id, limit_usd: limit}] = Budget.list_caps()
    assert Decimal.equal?(limit, Decimal.new("5.0"))

    # The cap row carries its own Edit/Delete controls (no DB-only "ghost" rows).
    assert has_element?(view, "#budget-edit-#{id}")
    assert has_element?(view, "#budget-delete-#{id}")

    # Edit loads it into the form (Save cap label + Cancel appear).
    view |> element("#budget-edit-#{id}") |> render_click()
    assert has_element?(view, "#budget-form-submit", "Save cap")
    assert has_element?(view, "#budget-form-cancel")

    # Saving a new limit upserts the SAME cap (keyed by scope/scope_id/period).
    view
    |> element("#budget-form")
    |> render_submit(%{
      "budget" => %{
        "scope" => "global",
        "scope_id" => "",
        "period" => "total",
        "limit_usd" => "25.0",
        "action" => "alert"
      }
    })

    assert [%{id: ^id, limit_usd: updated}] = Budget.list_caps()
    assert Decimal.equal?(updated, Decimal.new("25.0"))
  end

  test "the scope_id picker is hidden for Global and revealed for scoped caps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Default scope is Global → no Target picker / scope_id field.
    refute has_element?(view, "#budget_scope_id")

    # Switching scope to Orchestrator reveals the live id picker ("This console").
    html =
      view
      |> element("#budget-form")
      |> render_change(%{"budget" => %{"scope" => "orchestrator"}})

    assert html =~ "This console"
    assert has_element?(view, "#budget_scope_id")
  end
end
