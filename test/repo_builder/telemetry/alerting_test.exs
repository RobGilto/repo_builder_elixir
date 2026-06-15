defmodule RepoBuilder.Telemetry.AlertingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RepoBuilder.Telemetry.Alerting

  test "alerts when a recorded cost exceeds the threshold" do
    log =
      capture_log(fn ->
        Alerting.handle_event([:repo_builder, :cost, :recorded], %{amount: 99.0}, %{run_id: "r"},
          cost_threshold_usd: 10.0
        )
      end)

    assert log =~ "ALERT cost threshold exceeded"
  end

  test "does not alert for a cost under the threshold" do
    log =
      capture_log(fn ->
        Alerting.handle_event([:repo_builder, :cost, :recorded], %{amount: 1.0}, %{run_id: "r"},
          cost_threshold_usd: 10.0
        )
      end)

    refute log =~ "ALERT"
  end

  test "alerts on an Oban job exception" do
    log =
      capture_log(fn ->
        Alerting.handle_event(
          [:oban, :job, :exception],
          %{duration: 1},
          %{worker: "RepoBuilder.Workers.StepWorker"},
          []
        )
      end)

    assert log =~ "ALERT oban job exception"
  end
end
