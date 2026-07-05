defmodule RepoBuilder.Telemetry.LiveViewPerf do
  @moduledoc """
  Attaches structured Logger.info timing lines for LiveView mount,
  handle_event, and handle_params. Active only in `:dev` — attached from
  `Application.start/2` behind the `:lv_perf_handler` config flag set in
  `config/dev.exs`, so test/prod are unaffected.

  Emits lines like:

      [lv_perf] mount ConsoleLive 312 ms
      [lv_perf] event ConsoleLive toggle_view 3 ms
  """

  require Logger

  @handler_id "repo-builder-lv-perf"

  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:repo_builder, :console, :seed, :stop]
  ]

  @spec attach() :: :ok
  def attach do
    _ = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @spec handle_event([atom()], %{required(:duration) => integer()}, map(), nil) :: :ok
  def handle_event([:phoenix, :live_view, :mount, :stop], %{duration: duration}, meta, _cfg) do
    Logger.info("[lv_perf] mount #{short_name(meta[:socket])} #{to_ms(duration)} ms")
  end

  def handle_event(
        [:phoenix, :live_view, :handle_event, :stop],
        %{duration: duration},
        %{event: event} = meta,
        _cfg
      ) do
    Logger.info("[lv_perf] event #{short_name(meta[:socket])} #{event} #{to_ms(duration)} ms")
  end

  def handle_event(
        [:phoenix, :live_view, :handle_params, :stop],
        %{duration: duration},
        meta,
        _cfg
      ) do
    Logger.info("[lv_perf] params #{short_name(meta[:socket])} #{to_ms(duration)} ms")
  end

  def handle_event(
        [:repo_builder, :console, :seed, :stop],
        %{duration: duration},
        %{seed: seed},
        _cfg
      ) do
    Logger.info("[lv_perf] seed #{seed} #{to_ms(duration)} ms")
  end

  @spec to_ms(integer()) :: integer()
  defp to_ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  @spec short_name(Phoenix.LiveView.Socket.t() | nil) :: String.t()
  defp short_name(%{view: view}) when is_atom(view) do
    view |> Module.split() |> List.last()
  end

  defp short_name(_socket), do: "unknown"
end
