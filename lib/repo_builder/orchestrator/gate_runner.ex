defmodule RepoBuilder.Orchestrator.GateRunner do
  @moduledoc """
  Execute a resolved quality gate (quality-gate-plugins) and produce a structured
  `GateResult`.

  Per the plan's execution-surface decision, the orchestrator BEAM does NOT shell out into
  a target-repo toolchain. This module produces the ordered command PLAN (`plan/2`) and
  EVALUATES captured stage outputs (`run/3`) into a result — the actual `System.cmd` runs
  in the phase worker's own sandbox via the `run_quality_gate` tool handler, which injects
  the executor. `run/3` takes an `exec_fun` so it is fully testable with fixtures and stays
  execution-surface-agnostic.

  Stages run in ORDER; a strict red halts the gate (subsequent stages are `:skipped`) unless
  the failed stage is `continue_on_fail`. `:file_line` stages parse `path:line[:col]`
  diagnostics so the fix-worker gets located, self-correctable findings; `:summary` stages
  capture the output tail; `:none` stages capture nothing.
  """
  alias RepoBuilder.Orchestrator.GateResolver

  # Max diagnostics kept per stage and max chars of summary tail (bound the result so it can
  # never overflow the tool-result framing — same rationale as the Tools text caps).
  @max_diagnostics 50
  @summary_cap 2_000

  @typedoc "A parsed, located finding from a `:file_line` stage."
  @type diagnostic :: %{file: String.t(), line: pos_integer() | nil, message: String.t()}

  @typedoc "One stage's evaluated outcome."
  @type stage_result :: %{
          stage_id: String.t(),
          label: String.t(),
          command: String.t(),
          status: :passed | :failed | :skipped,
          exit_code: integer() | nil,
          diagnostics: [diagnostic()],
          summary: String.t() | nil
        }

  @typedoc "The whole gate's evaluated outcome."
  @type gate_result :: %{
          stack: String.t(),
          cadence: RepoBuilder.Plugins.QualityGate.cadence(),
          green: boolean(),
          failed_stage: String.t() | nil,
          stages: [stage_result()]
        }

  @typedoc "A raw captured stage output (from the worker sandbox / a fixture)."
  @type capture :: %{exit_code: integer(), output: String.t()}

  @doc "The ordered stages of `gate` for a cadence (`:per_phase` | `:pre_merge`)."
  @spec plan(GateResolver.t(), RepoBuilder.Plugins.QualityGate.cadence()) ::
          [GateResolver.ResolvedStage.t()]
  def plan(%GateResolver{stages: stages}, cadence) do
    Enum.filter(stages, &(&1.cadence == cadence))
  end

  @doc """
  The ordered command plan as JSON-friendly maps — what the tool hands the worker to run.
  """
  @spec command_plan(GateResolver.t(), RepoBuilder.Plugins.QualityGate.cadence()) :: [map()]
  def command_plan(%GateResolver{} = gate, cadence) do
    gate
    |> plan(cadence)
    |> Enum.map(
      &%{
        "stage_id" => &1.id,
        "label" => &1.label,
        "command" => &1.command,
        "strict" => &1.strict,
        "diagnostic" => to_string(&1.diagnostic)
      }
    )
  end

  @doc """
  Run (evaluate) `gate` for a cadence. `exec_fun` receives each `ResolvedStage` in order and
  returns its `%{exit_code, output}` capture (the worker's actual run, or a test fixture).
  Halts at the first strict failure — later stages become `:skipped` — unless the failed
  stage is `continue_on_fail`.
  """
  @spec run(
          GateResolver.t(),
          RepoBuilder.Plugins.QualityGate.cadence(),
          (GateResolver.ResolvedStage.t() -> capture())
        ) :: gate_result()
  def run(%GateResolver{stack: stack} = gate, cadence, exec_fun) when is_function(exec_fun, 1) do
    {results, _halted} =
      gate
      |> plan(cadence)
      |> Enum.map_reduce(false, fn stage, halted ->
        if halted do
          {skipped(stage), true}
        else
          result = evaluate(stage, exec_fun.(stage))
          {result, halt_after?(result, stage)}
        end
      end)

    failed = Enum.find(results, &(&1.status == :failed))

    %{
      stack: stack,
      cadence: cadence,
      green: failed == nil,
      failed_stage: failed && failed.stage_id,
      stages: results
    }
  end

  # A strict failure halts the remaining stages unless it is `continue_on_fail`.
  @spec halt_after?(stage_result(), GateResolver.ResolvedStage.t()) :: boolean()
  defp halt_after?(%{status: :failed}, %{strict: true, continue_on_fail: false}), do: true
  defp halt_after?(_result, _stage), do: false

  @spec skipped(GateResolver.ResolvedStage.t()) :: stage_result()
  defp skipped(stage) do
    %{
      stage_id: stage.id,
      label: stage.label,
      command: stage.command,
      status: :skipped,
      exit_code: nil,
      diagnostics: [],
      summary: nil
    }
  end

  @spec evaluate(GateResolver.ResolvedStage.t(), capture()) :: stage_result()
  defp evaluate(stage, %{exit_code: code} = capture) do
    output = Map.get(capture, :output, "")
    status = if code == 0, do: :passed, else: :failed

    %{
      stage_id: stage.id,
      label: stage.label,
      command: stage.command,
      status: status,
      exit_code: code,
      diagnostics: parse_diagnostics(stage.diagnostic, output, status),
      summary: summarize(stage.diagnostic, output, status)
    }
  end

  # Only parse diagnostics on a red stage (a green stage has nothing to fix).
  @spec parse_diagnostics(RepoBuilder.Plugins.QualityGate.diagnostic(), String.t(), atom()) ::
          [diagnostic()]
  defp parse_diagnostics(:file_line, output, :failed) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
    |> Enum.take(@max_diagnostics)
  end

  defp parse_diagnostics(_diagnostic, _output, _status), do: []

  # Match a leading `path:line[:col][: message]` — the near-universal compiler/linter shape.
  @line_re ~r/^\s*(?<file>[\w.\-\/]+\.\w+):(?<line>\d+)(?::\d+)?:?\s*(?<message>.*)$/

  @spec parse_line(String.t()) :: [diagnostic()]
  defp parse_line(line) do
    case Regex.named_captures(@line_re, line) do
      %{"file" => file, "line" => line_no, "message" => message} ->
        [%{file: file, line: to_int(line_no), message: String.trim(message)}]

      nil ->
        []
    end
  end

  @spec summarize(RepoBuilder.Plugins.QualityGate.diagnostic(), String.t(), atom()) ::
          String.t() | nil
  defp summarize(:summary, output, :failed) when is_binary(output) and output != "" do
    output |> tail() |> String.slice(0, @summary_cap)
  end

  defp summarize(_diagnostic, _output, _status), do: nil

  # The last ~20 lines of output (where a test/format summary lives).
  @spec tail(String.t()) :: String.t()
  defp tail(output) do
    output |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n") |> String.trim()
  end

  @spec to_int(String.t()) :: pos_integer() | nil
  defp to_int(string) do
    case Integer.parse(string) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  @doc "Serialize a `gate_result` to a string-keyed map for JSONB persistence / tool results."
  @spec to_map(gate_result()) :: map()
  def to_map(result) do
    %{
      "stack" => result.stack,
      "cadence" => to_string(result.cadence),
      "green" => result.green,
      "failed_stage" => result.failed_stage,
      "stages" => Enum.map(result.stages, &stage_to_map/1)
    }
  end

  @spec stage_to_map(stage_result()) :: map()
  defp stage_to_map(stage) do
    %{
      "stage_id" => stage.stage_id,
      "label" => stage.label,
      "command" => stage.command,
      "status" => to_string(stage.status),
      "exit_code" => stage.exit_code,
      "diagnostics" =>
        Enum.map(
          stage.diagnostics,
          &%{"file" => &1.file, "line" => &1.line, "message" => &1.message}
        ),
      "summary" => stage.summary
    }
  end
end
