defmodule RepoBuilder.Telemetry.Alerting do
  @moduledoc """
  Cost/error threshold alerting (BUILD_PROMPT.md §9/§13). Attaches telemetry handlers
  that log an ALERT when a per-run cost exceeds the configured USD threshold, or when
  an Oban job raises. Thresholds come from `config :repo_builder, :alerting`.
  """
  require Logger

  @handler_id "repo-builder-alerting"
  @events [[:oban, :job, :exception], [:repo_builder, :cost, :recorded]]

  @doc "Attach the alerting handlers. Idempotent across boots."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, config()) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Telemetry handler: emits a Logger ALERT when a threshold is crossed."
  @spec handle_event([atom()], map(), map(), keyword()) :: :ok
  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    Logger.error("ALERT oban job exception: worker=#{inspect(Map.get(metadata, :worker))}")
    :ok
  end

  def handle_event([:repo_builder, :cost, :recorded], %{amount: amount}, metadata, config) do
    threshold = config[:cost_threshold_usd]

    if is_number(threshold) and amount > threshold do
      Logger.warning(
        "ALERT cost threshold exceeded: #{amount} > #{threshold} (run #{inspect(Map.get(metadata, :run_id))})"
      )
    end

    :ok
  end

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :alerting, [])
end
