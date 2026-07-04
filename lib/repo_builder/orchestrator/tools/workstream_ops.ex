defmodule RepoBuilder.Orchestrator.Tools.WorkstreamOps do
  @moduledoc """
  Workstream tools (spec-driven phased orchestration): create/plan/record/list/
  get/close workstreams plus the brain's own `compact_self` durable swap.
  Extracted verbatim from the monolithic `Orchestrator.Tools` (audit F3) —
  behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      broadcast_workstreams: 1,
      changeset_reason: 1,
      fetch_string: 2,
      normalize_reason: 1
    ]

  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrator.WorkstreamPhase
  alias RepoBuilder.Orchestrator.Workstreams

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  # Soft cap on concurrently-active workstreams (orchestration-adw-loop): past this the brain
  # is warned (not refused) so it consolidates rather than over-committing its own context.
  @active_workstream_cap 5

  @spec create_workstream(Ecto.UUID.t(), map()) :: result()
  def create_workstream(orchestrator_id, args) do
    with {:ok, title} <- fetch_string(args, "title"),
         {:ok, goal} <- fetch_string(args, "goal") do
      attrs = %{
        title: title,
        goal: goal,
        definition_of_done: blank_to_nil(args["definition_of_done"])
      }

      case Workstreams.create_workstream(orchestrator_id, attrs) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)

          {:ok,
           %{"status" => "created", "workstream_id" => workstream.id, "title" => workstream.title}
           |> maybe_warn_active_cap(orchestrator_id)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec plan_phases(Ecto.UUID.t(), map()) :: result()
  def plan_phases(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, phases} <- normalize_phases(args["phases"]) do
      case Workstreams.plan_phases(orchestrator_id, ref, phases) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)

          {:ok,
           %{"status" => "planned", "workstream_id" => workstream.id, "phases" => length(phases)}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @spec record_stage(Ecto.UUID.t(), map()) :: result()
  def record_stage(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, stage} <- fetch_string(args, "stage"),
         {:ok, outcome} <- fetch_string(args, "outcome") do
      attrs = %{
        stage: stage,
        outcome: outcome,
        artifact: blank_to_nil(args["artifact"]),
        worker: blank_to_nil(args["worker"]),
        note: blank_to_nil(args["note"]),
        gate: gate_evidence(args["gate"])
      }

      case Workstreams.record_stage(orchestrator_id, ref, attrs) do
        {:ok, _workstream} ->
          _ = broadcast_workstreams(orchestrator_id)
          {:ok, workstream_record_map(orchestrator_id, ref)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  # Accept an already-structured GateResult map as stage evidence; anything else ⇒ nil.
  @spec gate_evidence(term()) :: map() | nil
  defp gate_evidence(%{} = gate), do: gate
  defp gate_evidence(_gate), do: nil

  @spec list_workstreams(Ecto.UUID.t()) :: result()
  def list_workstreams(orchestrator_id) do
    rows = orchestrator_id |> Workstreams.list_workstreams() |> Enum.map(&index_row_map/1)
    {:ok, %{"workstreams" => rows, "count" => length(rows)}}
  end

  @spec get_workstream(Ecto.UUID.t(), map()) :: result()
  def get_workstream(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream") do
      case Workstreams.get_workstream(orchestrator_id, ref) do
        {:ok, record} -> {:ok, record_map(record)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  @spec close_workstream(Ecto.UUID.t(), map()) :: result()
  def close_workstream(orchestrator_id, args) do
    with {:ok, ref} <- fetch_string(args, "workstream"),
         {:ok, status} <- fetch_string(args, "status") do
      case Workstreams.close_workstream(orchestrator_id, ref, status) do
        {:ok, workstream} ->
          _ = broadcast_workstreams(orchestrator_id)
          {:ok, %{"status" => to_string(workstream.status), "workstream_id" => workstream.id}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @doc """
  Compact the orchestrator's OWN context (the brain's durable swap): schedule a `/compact`
  turn on its own session; the queue then reseeds the next turn with the workstream index
  (rehydrate-on-resume). Delegates to the orchestrator Server (task 8).
  """
  @spec compact_self(Ecto.UUID.t()) :: result()
  def compact_self(orchestrator_id) do
    case Server.compact_self(orchestrator_id) do
      {:ok, :compacting} -> {:ok, %{"status" => "compacting"}}
      {:error, reason} -> {:error, normalize_reason(reason)}
    end
  end

  # Active-workstream cap (orchestration-adw-loop edge case): keep the brain from over-committing
  # its own context. Past the soft cap the workstream is still created, but the result carries a
  # warning so the brain consolidates rather than spawning yet more parallel scratchpads.
  # Inference-only spec — the concrete map (optionally with a "warning" key) narrows below `map()`.
  defp maybe_warn_active_cap(result, orchestrator_id) do
    active =
      orchestrator_id
      |> Workstreams.list_workstreams()
      |> Enum.count(&(&1.status in [:running, :blocked]))

    if active > @active_workstream_cap do
      Map.put(
        result,
        "warning",
        "#{active} active workstreams exceeds the soft cap of #{@active_workstream_cap} — " <>
          "finish or close some before opening more so you don't over-commit your context"
      )
    else
      result
    end
  end

  # Re-read the full record after a mutation for the tool result (string-keyed, JSON-encodable).
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp workstream_record_map(orchestrator_id, ref) do
    case Workstreams.get_workstream(orchestrator_id, ref) do
      {:ok, record} -> record_map(record)
      {:error, _reason} -> %{"status" => "recorded"}
    end
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp index_row_map(row) do
    %{
      "id" => row.id,
      "title" => row.title,
      "status" => to_string(row.status),
      "phase" => row.phase,
      "current_stage" => row.current_stage && to_string(row.current_stage),
      "next_action" => row.next_action,
      "stall_count" => row.stall_count,
      "focus" => row.focus
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp record_map(record) do
    %{
      "id" => record.id,
      "title" => record.title,
      "goal" => record.goal,
      "definition_of_done" => record.definition_of_done,
      "status" => to_string(record.status),
      "stall_count" => record.stall_count,
      "current_phase_position" => record.current_phase_position,
      "next_action" => record.next_action,
      "focus" => record.focus,
      "phases" => Enum.map(record.phases, &phase_map/1)
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp phase_map(phase) do
    %{
      "position" => phase.position,
      "title" => phase.title,
      "description" => phase.description,
      "definition_of_done" => phase.definition_of_done,
      "spec_path" => phase.spec_path,
      "status" => to_string(phase.status),
      "current_stage" => to_string(phase.current_stage),
      "kind" => to_string(phase.kind),
      "surface" => phase.surface && to_string(phase.surface),
      "iteration" => phase.iteration,
      "stages" => phase.stages,
      "completed" => phase.completed,
      "remaining" => phase.remaining
    }
  end

  # Validate + normalize the `phases` array from the tool args into the context's phase maps.
  @spec normalize_phases(term()) :: {:ok, [map()]} | {:error, reason()}
  defp normalize_phases(phases) when is_list(phases) and phases != [] do
    normalized =
      Enum.map(phases, fn phase when is_map(phase) ->
        %{
          title: blank_to_nil(phase["title"]),
          description: blank_to_nil(phase["description"]),
          definition_of_done: blank_to_nil(phase["definition_of_done"]),
          # UI/UX polish phase (iterative-ui-ux): a phase may declare `kind: "ui_ux"` + a
          # `surface`. Absent/blank/unknown ⇒ nil, and the context defaults to a `:backend`
          # phase, so existing plans are byte-for-byte unchanged.
          kind: normalize_phase_kind(phase["kind"]),
          surface: normalize_phase_surface(phase["surface"])
        }
      end)

    if Enum.all?(normalized, &is_binary(&1.title)),
      do: {:ok, normalized},
      else: {:error, "each phase requires a title"}
  rescue
    _error -> {:error, "phases must be an array of objects"}
  end

  defp normalize_phases(_phases), do: {:error, "phases must be a non-empty array"}

  # Map a phase's wire `kind`/`surface` to a validated atom (or nil). Unknown strings drop to
  # nil so a malformed value degrades to the backend default rather than failing the plan.
  @spec normalize_phase_kind(term()) :: WorkstreamPhase.kind() | nil
  defp normalize_phase_kind(kind) when kind in ["backend", "ui_ux"], do: String.to_atom(kind)
  defp normalize_phase_kind(_kind), do: nil

  @spec normalize_phase_surface(term()) :: WorkstreamPhase.surface() | nil
  defp normalize_phase_surface(surface) when surface in ["web", "desktop", "tui"],
    do: String.to_atom(surface)

  defp normalize_phase_surface(_surface), do: nil
end
