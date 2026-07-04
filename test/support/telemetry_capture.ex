defmodule RepoBuilderWeb.TelemetryCapture do
  @moduledoc """
  Test helper for capturing LiveView telemetry events and asserting timing
  thresholds. Usage:

      TelemetryCapture.capture(fn ->
        {:ok, lv, _} = live(conn, ~p"/")
        render(lv)
      end)
      |> TelemetryCapture.assert_mount_under(ConsoleLive, 500)
  """

  import ExUnit.Assertions

  @lv_events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_params, :stop]
  ]

  @type measurement :: %{
          event: [atom()],
          measurements: map(),
          metadata: map(),
          duration_ms: non_neg_integer()
        }

  @doc "Run `fun` with the LiveView telemetry events attached; return what fired."
  @spec capture((-> any())) :: [measurement()]
  def capture(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = "telemetry-capture-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      @lv_events,
      fn event, measurements, metadata, _cfg ->
        ms = System.convert_time_unit(measurements[:duration], :native, :millisecond)

        send(
          test_pid,
          {:tel_event, ref,
           %{event: event, measurements: measurements, metadata: metadata, duration_ms: ms}}
        )
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_events(ref)
  end

  @doc "Assert every captured mount of `view_module` completed within `max_ms`."
  @spec assert_mount_under([measurement()], module(), pos_integer()) :: [measurement()]
  def assert_mount_under(events, view_module, max_ms) do
    mounts =
      Enum.filter(events, fn e ->
        e.event == [:phoenix, :live_view, :mount, :stop] and
          match?(%{socket: %{view: ^view_module}}, e.metadata)
      end)

    assert mounts != [], "No mount event captured for #{inspect(view_module)}"

    Enum.each(mounts, fn e ->
      assert e.duration_ms <= max_ms,
             "#{inspect(view_module)} mount took #{e.duration_ms} ms, expected <= #{max_ms} ms"
    end)

    events
  end

  @doc "Assert every captured `event_name` handle_event of `view_module` ran within `max_ms`."
  @spec assert_event_under([measurement()], module(), String.t(), pos_integer()) ::
          [measurement()]
  def assert_event_under(events, view_module, event_name, max_ms) do
    matching =
      Enum.filter(events, fn e ->
        e.event == [:phoenix, :live_view, :handle_event, :stop] and
          e.metadata[:event] == event_name and
          match?(%{socket: %{view: ^view_module}}, e.metadata)
      end)

    assert matching != [],
           "No handle_event '#{event_name}' captured for #{inspect(view_module)}"

    Enum.each(matching, fn e ->
      assert e.duration_ms <= max_ms,
             "#{inspect(view_module)} #{event_name} took #{e.duration_ms} ms, " <>
               "expected <= #{max_ms} ms"
    end)

    events
  end

  # Drain the mailbox of captured events (non-blocking after the fun completes).
  @spec collect_events(reference()) :: [measurement()]
  defp collect_events(ref), do: collect_events(ref, [])

  @spec collect_events(reference(), [measurement()]) :: [measurement()]
  defp collect_events(ref, acc) do
    receive do
      {:tel_event, ^ref, event} -> collect_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
