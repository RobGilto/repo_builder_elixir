defmodule RepoBuilderWeb.ConsoleLive.BrainPanel do
  @moduledoc """
  Brain panel of the console (docs/audit-2026-07.md F3, Phase 3): the orchestrator
  harness/provider/model selection, context clear, and the per-project + global-default
  agent-models (worker roster) event handlers extracted verbatim from `ConsoleLive`.
  `ConsoleLive` delegates the panel's events here; the selection reflector
  (`assign_orchestrator_selection/2`) and roster row builders live in `ConsoleLive.Shared`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.{Orchestrators, Settings}
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(set_harness set_provider set_model clear_orchestrator_context open_agent_models
             set_agent_model clear_agent_model set_default_agent_model)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  # Switch the orchestrator's harness (Claude ⇄ pi ⇄ …). Applies that harness's
  # provider/model defaults (Claude ⇒ anthropic/opus; pi ⇒ operator-chosen), so the
  # header reflects the full selection. The next run_turn picks it up.
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("set_harness", %{"harness" => harness}, socket) do
    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_harness(&1, harness),
      "Could not switch harness"
    )
  end

  # Set the orchestrator's provider (open identity). An empty selection clears it.
  def handle_event("set_provider", %{"provider" => provider}, socket) do
    provider = Shared.nilify_blank(provider)

    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_provider(&1, provider),
      "Could not set provider"
    )
  end

  # Set the orchestrator's model (free text / suggested). Empty clears it. Clearing the
  # resumable session is handled in `Orchestrators.set_model/2`, so the context bar
  # zeroes via `assign_orchestrator_selection` (a model switch starts the next turn fresh).
  def handle_event("set_model", %{"model" => model}, socket) do
    model = Shared.nilify_blank(model)

    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_model(&1, model),
      "Could not set model"
    )
  end

  # Clear the orchestrator's conversation context: drop the resumable session id so the
  # next turn starts a fresh conversation, which zeroes the context-window bar (the
  # visible chat log is persisted history and is left in place).
  def handle_event("clear_orchestrator_context", _params, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.set_session(id, nil) do
          {:ok, orchestrator} ->
            {:noreply,
             socket
             |> Shared.assign_orchestrator_selection(orchestrator)
             |> put_flash(:info, "Context cleared — the next turn starts fresh")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not clear context")}
        end
    end
  end

  # Re-fetch the orchestrator from the DB when the user opens the agent-models modal
  # so the panel always shows live state (including out-of-band mutations).
  def handle_event("open_agent_models", _params, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, socket}

      id ->
        case Orchestrators.fetch(id) do
          {:ok, orchestrator} ->
            {:noreply, Shared.assign_orchestrator_selection(socket, orchestrator)}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # Assign a worker category's harness/provider/model (agent-models modal). Cascade:
  # changing the harness clears provider+model; changing the provider clears model.
  # On success: transiently set `agent_model_saved: true` for the "Saved ✓" chip.
  def handle_event("set_agent_model", %{"category" => category} = params, socket) do
    stored = Enum.find(socket.assigns.agent_model_rows, %{}, &(&1.category == category))
    attrs = agent_model_attrs(params, stored)

    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.set_agent_model(id, category, attrs) do
          {:ok, orchestrator} ->
            Process.send_after(self(), :clear_agent_model_saved, 2_000)

            {:noreply,
             socket
             |> Shared.assign_orchestrator_selection(orchestrator)
             |> assign(:agent_model_saved, true)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not set agent model")}
        end
    end
  end

  # Clear a worker category's per-project override so the tier re-inherits the global
  # default (the "reset to default" affordance in the agent-models modal).
  def handle_event("clear_agent_model", %{"category" => category}, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.clear_agent_model(id, category) do
          {:ok, orchestrator} ->
            {:noreply, Shared.assign_orchestrator_selection(socket, orchestrator)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not reset agent model")}
        end
    end
  end

  # Save one tier of the GLOBAL default roster (Settings → Default Models tab). Same
  # cascade as `set_agent_model` (harness change clears provider+model). Persists via the
  # Settings context; new projects inherit this default.
  def handle_event("set_default_agent_model", %{"category" => category} = params, socket) do
    stored = Enum.find(socket.assigns.default_model_rows, %{}, &(&1.category == category))
    attrs = agent_model_attrs(params, stored)

    case Settings.set_default_agent_model(
           category,
           attrs["harness"],
           attrs["provider"],
           attrs["model"]
         ) do
      {:ok, _roster} ->
        Process.send_after(self(), :clear_default_model_saved, 2_000)

        {:noreply,
         socket
         |> assign(:default_model_rows, Shared.default_model_rows())
         |> assign(:default_model_saved, true)}

      {:error, :invalid_category} ->
        {:noreply, put_flash(socket, :error, "Unknown worker category")}

      {:error, :unknown_harness} ->
        {:noreply, put_flash(socket, :error, "Pick a registered harness first")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save default model")}
    end
  end

  # --- private ---

  # Cascade an agent-models row change, driven by an *actual* value change against
  # the tier's currently-stored entry (`stored`) — not merely by which input fired.
  # Changing the harness clears provider+model; changing the provider clears model;
  # a no-op `change` event (LiveView reconnect reconciliation, or re-picking the same
  # option) preserves the stored downstream fields so a saved model is never wiped.
  @spec agent_model_attrs(map(), map()) :: %{optional(String.t()) => String.t() | nil}
  defp agent_model_attrs(%{"_target" => ["harness" | _]} = params, stored) do
    submitted = Shared.nilify_blank(params["harness"])

    if submitted == stored[:harness] do
      # Harness unchanged: spurious cascade. Keep the stored row intact.
      %{
        "harness" => stored[:harness],
        "provider" => stored[:provider],
        "model" => stored[:model]
      }
    else
      %{"harness" => submitted, "provider" => nil, "model" => nil}
    end
  end

  defp agent_model_attrs(%{"_target" => ["provider" | _]} = params, stored) do
    submitted = Shared.nilify_blank(params["provider"])

    %{
      "harness" => Shared.nilify_blank(params["harness"]),
      "provider" => submitted,
      # Provider unchanged: keep the stored model; otherwise clear the now-invalid model.
      "model" => if(submitted == stored[:provider], do: stored[:model], else: nil)
    }
  end

  defp agent_model_attrs(params, _stored) do
    %{
      "harness" => Shared.nilify_blank(params["harness"]),
      "provider" => Shared.nilify_blank(params["provider"]),
      "model" => Shared.nilify_blank(params["model"])
    }
  end
end
