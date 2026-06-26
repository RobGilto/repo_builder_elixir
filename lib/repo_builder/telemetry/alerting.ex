defmodule RepoBuilder.Telemetry.Alerting do
  @moduledoc """
  Error alerting (BUILD_PROMPT.md §9/§13). Attaches a telemetry handler that logs an
  ALERT when an Oban job raises.

  The legacy global cost-threshold handler has been RETIRED (issue per-project-cost-
  tracking): the `config :repo_builder, :alerting, :cost_threshold_usd` value is now folded
  into a seeded global `:alert` Budget cap by `RepoBuilder.Budget.seed_default_cap/0`, so
  there is exactly one alerting mechanism (`Budget.Guard`) — which additionally supports
  per-project/session/daily caps with warn → pause → hard-stop. Only the Oban exception
  handler (unrelated to cost) remains here.
  """
  require Logger

  @handler_id "repo-builder-alerting"
  @events [[:oban, :job, :exception]]

  @doc "Attach the Oban-exception alerting handler. Idempotent across boots."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Telemetry handler: emits a Logger ALERT when an Oban job raises."
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    Logger.error("ALERT oban job exception: worker=#{inspect(Map.get(metadata, :worker))}")
    :ok
  end
end
