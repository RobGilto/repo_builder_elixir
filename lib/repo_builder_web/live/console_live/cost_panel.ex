defmodule RepoBuilderWeb.ConsoleLive.CostPanel do
  @moduledoc """
  Cost panel of the console (docs/audit-2026-07.md F3, Phase 3): the per-project cost
  clear/restore, model-price catalog CRUD, and budget-guardrail event handlers extracted
  verbatim from `ConsoleLive`. `ConsoleLive` delegates the panel's events here; the
  cross-panel loaders (`load_cost_center/1`, `seed_budget/1`) live in
  `ConsoleLive.Shared`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.{Budget, CostCenter, Logs}
  alias RepoBuilder.Budget.Cap
  alias RepoBuilder.CostCenter.ModelPrice
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(clear_project_costs restore_project_costs save_price edit_price cancel_edit
             delete_price budget_form_change edit_budget cancel_edit_budget save_budget
             delete_budget reset_budget toggle_kill_switch)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  # Clear (soft-hide) the active project's cost rows — recoverable via "Restore".
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("clear_project_costs", _params, socket) do
    case socket.assigns[:active_project_id] do
      id when is_binary(id) ->
        count = Logs.hide_logs_for_project(id)

        {:noreply,
         socket
         |> Shared.load_cost_center()
         |> put_flash(:info, "Cleared #{count} cost row(s) (restorable)")}

      _ ->
        {:noreply, put_flash(socket, :error, "Select a project first")}
    end
  end

  # Restore (reveal) the active project's previously-cleared cost rows.
  def handle_event("restore_project_costs", _params, socket) do
    case socket.assigns[:active_project_id] do
      id when is_binary(id) ->
        count = Logs.release_hidden_logs_for_project(id)

        {:noreply,
         socket
         |> Shared.load_cost_center()
         |> put_flash(:info, "Restored #{count} cost row(s)")}

      _ ->
        {:noreply, put_flash(socket, :error, "Select a project first")}
    end
  end

  # Save a catalog price (issue-cost-center). Routes to `update_price/2` when an edit is in
  # flight (identity key fields dropped so the row can never be repointed, §key-immutability)
  # or `upsert_price/1` when creating. On success re-derive the catalog + rollup and reset
  # to create mode; on a validation error re-render the form with the changeset (staying in
  # edit mode); a stale id (row deleted concurrently) falls back to create mode.
  def handle_event("save_price", %{"model_price" => params}, socket) do
    result =
      case socket.assigns.editing_price_id do
        nil ->
          CostCenter.upsert_price(params)

        id ->
          case CostCenter.get_price(id) do
            nil -> {:error, :not_found}
            price -> CostCenter.update_price(price, Map.drop(params, ~w(harness provider model)))
          end
      end

    case result do
      {:ok, _price} ->
        {:noreply, socket |> Shared.load_cost_center() |> reset_price_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :price_form, to_form(changeset, as: :model_price))}

      {:error, :not_found} ->
        {:noreply, socket |> Shared.load_cost_center() |> reset_price_form()}
    end
  end

  # Load a catalog row into the form and flip into edit mode. A stale id (concurrent
  # delete) no-ops rather than crashing.
  def handle_event("edit_price", %{"id" => id}, socket) do
    case CostCenter.get_price(id) do
      nil ->
        {:noreply, socket}

      %ModelPrice{} = price ->
        {:noreply,
         assign(socket,
           editing_price_id: price.id,
           price_form: to_form(ModelPrice.changeset(price, %{}), as: :model_price)
         )}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, reset_price_form(socket)}
  end

  def handle_event("delete_price", %{"id" => id}, socket) do
    _ = CostCenter.delete_price(id)
    socket = Shared.load_cost_center(socket)

    socket =
      if socket.assigns.editing_price_id == id, do: reset_price_form(socket), else: socket

    {:noreply, socket}
  end

  # --- budget guardrails (issue-budget-guardrails) ---

  # Track the form's selected scope as the operator changes it, so the scope_id picker can
  # show/hide (and swap orchestrator-vs-workflow targets) without a submit. Rebuild the form
  # from the in-flight params so typed values survive the re-render.
  def handle_event("budget_form_change", %{"budget" => params}, socket) do
    changeset = Cap.changeset(%Cap{}, params)

    {:noreply,
     assign(socket,
       budget_form: to_form(changeset, as: :budget),
       budget_scope: params["scope"] || "global",
       # Recompute live targets so the picker reflects orchestrators/workflows present
       # right now (the mount seed runs before orchestrator assignment / before new runs).
       budget_scope_targets: Shared.budget_scope_targets(socket)
     )}
  end

  # Load an existing cap (from the merged DB+live rows, so even a not-yet-reconciled cap is
  # editable) into the form. Submitting upserts it, which also reconciles any memory-vs-DB
  # drift by writing the row back.
  def handle_event("edit_budget", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.budget_caps, &(&1.cap.id == id)) do
      %{cap: cap} ->
        {:noreply,
         assign(socket,
           budget_form: to_form(Cap.changeset(cap, %{}), as: :budget),
           budget_scope: to_string(cap.scope),
           budget_scope_targets: Shared.budget_scope_targets(socket),
           budget_editing?: true
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_budget", _params, socket) do
    {:noreply, reset_budget_form(socket)}
  end

  def handle_event("save_budget", %{"budget" => params}, socket) do
    case Budget.upsert_cap(params) do
      {:ok, _cap} ->
        # A new/edited cap changes the live policy; force the Guard to reload + reconcile.
        _ = Budget.Guard.refresh()
        {:noreply, socket |> Shared.refresh_budget() |> reset_budget_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :budget_form, to_form(changeset, as: :budget))}
    end
  end

  def handle_event("delete_budget", %{"id" => id}, socket) do
    _ = Budget.delete_cap(id)
    _ = Budget.Guard.refresh()
    {:noreply, Shared.refresh_budget(socket)}
  end

  def handle_event("reset_budget", %{"id" => id}, socket) do
    _ = Budget.Guard.reset_cap(id)
    {:noreply, Shared.refresh_budget(socket)}
  end

  def handle_event("toggle_kill_switch", _params, socket) do
    if socket.assigns.budget_state.kill_switch? do
      _ = Budget.Guard.release_all()
    else
      _ = Budget.Guard.engage_kill_switch()
    end

    {:noreply, Shared.refresh_budget(socket)}
  end

  # --- private ---

  @spec reset_price_form(Socket.t()) :: Socket.t()
  defp reset_price_form(socket) do
    assign(socket,
      editing_price_id: nil,
      price_form: to_form(ModelPrice.changeset(%ModelPrice{}, %{}), as: :model_price)
    )
  end

  @spec reset_budget_form(Socket.t()) :: Socket.t()
  defp reset_budget_form(socket) do
    assign(socket,
      budget_form: to_form(Cap.changeset(%Cap{}, %{}), as: :budget),
      budget_scope: "global",
      budget_editing?: false
    )
  end
end
