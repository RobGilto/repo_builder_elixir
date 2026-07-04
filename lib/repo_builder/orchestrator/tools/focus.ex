defmodule RepoBuilder.Orchestrator.Tools.Focus do
  @moduledoc """
  Focus discipline (two-level: per-workstream + orchestrator fallback): the
  `set_focus`/`clear_focus` tools plus the deterministic focus gate consulted by
  `Tools.call/3` before dispatching a budget-spending worker tool. Extracted
  verbatim from the monolithic `Orchestrator.Tools` (audit F3) — behaviour is
  byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      broadcast_ledger: 1,
      broadcast_workstreams: 1,
      changeset_reason: 1,
      fetch_string: 2
    ]

  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.TaskLedger
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrator.Workstream
  alias RepoBuilder.Orchestrator.Workstreams

  @type result :: Shared.result()

  # Budget-spending WORKER tools blocked by the focus gate (focus discipline). `plan_phases` is
  # deliberately absent — it is the workstream-DECLARATION step, which must run before a
  # meaningful focus can be named (the analogue of tilldone "declare your tasks").
  @focus_gated_tools ~w(command_agent create_agent start_adw)

  @doc """
  Set the focus for the targeted scope: a `workstream` ref focuses that parallel stream,
  otherwise the orchestrator itself (untagged work). Blank focus is rejected at the boundary.
  """
  @spec set_focus(Ecto.UUID.t(), map()) :: result()
  def set_focus(orchestrator_id, args) do
    with {:ok, focus} <- fetch_string(args, "focus") do
      case blank_to_nil(args["workstream"]) do
        nil -> set_orchestrator_focus(orchestrator_id, focus)
        ref -> set_workstream_focus(orchestrator_id, ref, focus)
      end
    end
  end

  @spec set_orchestrator_focus(Ecto.UUID.t(), String.t()) :: result()
  defp set_orchestrator_focus(orchestrator_id, focus) do
    case Ledgers.set_focus(orchestrator_id, focus) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "focused", "scope" => "orchestrator", "focus" => focus}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec set_workstream_focus(Ecto.UUID.t(), String.t(), String.t()) :: result()
  defp set_workstream_focus(orchestrator_id, ref, focus) do
    case Workstreams.set_focus(orchestrator_id, ref, focus) do
      {:ok, _workstream} ->
        _ = broadcast_workstreams(orchestrator_id)

        {:ok,
         %{"status" => "focused", "scope" => "workstream", "workstream" => ref, "focus" => focus}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @doc "Clear the focus for the targeted scope (its stretch of work is verified done)."
  @spec clear_focus(Ecto.UUID.t(), map()) :: result()
  def clear_focus(orchestrator_id, args) do
    case blank_to_nil(args["workstream"]) do
      nil -> clear_orchestrator_focus(orchestrator_id)
      ref -> clear_workstream_focus(orchestrator_id, ref)
    end
  end

  @spec clear_orchestrator_focus(Ecto.UUID.t()) :: result()
  defp clear_orchestrator_focus(orchestrator_id) do
    case Ledgers.clear_focus(orchestrator_id) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "focus_cleared", "scope" => "orchestrator"}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec clear_workstream_focus(Ecto.UUID.t(), String.t()) :: result()
  defp clear_workstream_focus(orchestrator_id, ref) do
    case Workstreams.clear_focus(orchestrator_id, ref) do
      {:ok, _workstream} ->
        _ = broadcast_workstreams(orchestrator_id)
        {:ok, %{"status" => "focus_cleared", "scope" => "workstream", "workstream" => ref}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @doc """
  The deterministic, scope-aware focus gate: refuse a budget-spending worker tool when the
  scope it targets has no focus. A call naming a `workstream` is gated against THAT stream's
  focus; an untagged call against the orchestrator-level focus. Never engages for ungated
  tools, a disabled gate, an unresolvable/non-running workstream, or an absent active goal.
  """
  @spec gate_block(String.t(), Ecto.UUID.t(), map()) :: :ok | {:error, :focus_required}
  def gate_block(tool, orchestrator_id, args) do
    if focus_gate_enabled?() and tool in @focus_gated_tools and
         scope_unfocused?(orchestrator_id, args) do
      {:error, :focus_required}
    else
      :ok
    end
  end

  # True when the tool's target scope is an active/running unit with a blank focus.
  @spec scope_unfocused?(Ecto.UUID.t(), map()) :: boolean()
  defp scope_unfocused?(orchestrator_id, args) do
    case targeted_workstream(orchestrator_id, args) do
      %Workstream{} = ws -> blank?(ws.focus)
      nil -> orchestrator_unfocused?(orchestrator_id)
    end
  end

  # The `:running` workstream a call targets via its `workstream` ref, or nil (untagged, an
  # unresolvable ref, or a non-running stream — the last two fall through to normal dispatch).
  @spec targeted_workstream(Ecto.UUID.t(), map()) :: Workstream.t() | nil
  defp targeted_workstream(orchestrator_id, args) do
    with ref when is_binary(ref) <- blank_to_nil(args["workstream"]),
         {:ok, %Workstream{status: :running} = ws} <- Workstreams.resolve(orchestrator_id, ref) do
      ws
    else
      _ -> nil
    end
  end

  @spec orchestrator_unfocused?(Ecto.UUID.t()) :: boolean()
  defp orchestrator_unfocused?(orchestrator_id) do
    case Ledgers.current(orchestrator_id) do
      %TaskLedger{focus: focus} -> blank?(focus)
      nil -> false
    end
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(value), do: is_nil(blank_to_nil(value))

  @spec focus_gate_enabled?() :: boolean()
  defp focus_gate_enabled?,
    do: Keyword.get(Application.get_env(:repo_builder, :orchestrator, []), :focus_gate, true)
end
