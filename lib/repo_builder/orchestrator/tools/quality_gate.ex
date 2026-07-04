defmodule RepoBuilder.Orchestrator.Tools.QualityGate do
  @moduledoc """
  Quality-gate tool (quality-gate-plugins): resolve + run the bound project's
  stack-aware five-stage green gate for a phase's `:test` stage — plan mode
  (ordered command plan) or evaluate mode (worker-captured outputs → GateResult).
  Extracted verbatim from the monolithic `Orchestrator.Tools` (audit F3) —
  behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared, only: [orchestrator_project_id: 1]

  alias RepoBuilder.Orchestrator.GateResolver
  alias RepoBuilder.Orchestrator.GateRunner
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  @doc """
  Resolve + run the project's stack-aware quality gate for a phase's `:test` stage. With no
  `outputs` it returns the ordered COMMAND PLAN the phase worker executes; with `outputs`
  (the worker's captured exit codes + text) it EVALUATES them into a structured GateResult.
  The orchestrator BEAM never shells out — execution stays in the worker sandbox.
  """
  @spec run_quality_gate(Ecto.UUID.t(), map()) :: result()
  def run_quality_gate(orchestrator_id, args) do
    with {:ok, cadence} <- cast_gate_cadence(args["cadence"]),
         {:ok, gate} <- resolve_project_gate(orchestrator_id) do
      case normalize_gate_outputs(args["outputs"]) do
        {:ok, nil} -> {:ok, gate_plan_map(gate, cadence)}
        {:ok, outputs} -> {:ok, gate_result_map(gate, cadence, outputs)}
      end
    end
  end

  # The resolved gate for the orchestrator's bound project. `:no_project`/`:no_gate` are honest
  # errors the brain can act on (register a project / install a gate plugin).
  @spec resolve_project_gate(Ecto.UUID.t()) :: {:ok, GateResolver.t()} | {:error, reason()}
  defp resolve_project_gate(orchestrator_id) do
    with project_id when is_binary(project_id) <-
           orchestrator_project_id(orchestrator_id) || :no_project,
         {:ok, %Project{} = project} <- fetch_gate_project(project_id) do
      case GateResolver.resolve(project) do
        {:ok, gate} -> {:ok, gate}
        {:error, :none} -> {:error, :no_gate}
      end
    else
      :no_project -> {:error, :no_project}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_gate_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :project_not_found}
  defp fetch_gate_project(project_id) do
    case Projects.fetch_project(project_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, :project_not_found}
    end
  end

  @spec cast_gate_cadence(term()) :: {:ok, :per_phase | :pre_merge} | {:error, reason()}
  defp cast_gate_cadence(nil), do: {:ok, :per_phase}
  defp cast_gate_cadence("per_phase"), do: {:ok, :per_phase}
  defp cast_gate_cadence("pre_merge"), do: {:ok, :pre_merge}
  defp cast_gate_cadence(_other), do: {:error, "cadence must be per_phase or pre_merge"}

  # Normalize the optional `outputs` array into a `%{stage_id => %{exit_code, output}}` lookup,
  # or nil when absent/empty (plan mode). A malformed entry is dropped.
  @spec normalize_gate_outputs(term()) :: {:ok, map() | nil}
  defp normalize_gate_outputs(list) when is_list(list) and list != [] do
    {:ok, Enum.reduce(list, %{}, &maybe_put_output(&2, &1))}
  end

  defp normalize_gate_outputs(_list), do: {:ok, nil}

  @spec maybe_put_output(map(), term()) :: map()
  defp maybe_put_output(acc, %{"stage_id" => id, "exit_code" => code} = entry)
       when is_binary(id) and is_integer(code) do
    Map.put(acc, id, %{exit_code: code, output: to_string(entry["output"] || "")})
  end

  defp maybe_put_output(acc, _entry), do: acc

  # Evaluate the gate against the worker-captured outputs (exec_fun reads the lookup; a stage
  # with no captured output is treated as a clean pass so a partial report can't false-red).
  @spec gate_result_map(GateResolver.t(), :per_phase | :pre_merge, map()) :: map()
  defp gate_result_map(gate, cadence, outputs) do
    result =
      GateRunner.run(gate, cadence, fn stage ->
        Map.get(outputs, stage.id, %{exit_code: 0, output: ""})
      end)

    GateRunner.to_map(result)
    |> Map.put("mode", "result")
    |> Map.put("source", to_string(gate.source))
    |> Map.put("typed_enforcement", to_string(gate.typed_enforcement))
    |> Map.put("degraded", gate.degraded)
  end

  # The ordered command plan the worker executes (plan mode).
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written `map()`.
  defp gate_plan_map(gate, cadence) do
    %{
      "mode" => "plan",
      "stack" => gate.stack,
      "source" => to_string(gate.source),
      "cadence" => to_string(cadence),
      "typed_enforcement" => to_string(gate.typed_enforcement),
      "degraded" => gate.degraded,
      "commands" => GateRunner.command_plan(gate, cadence)
    }
  end
end
