defmodule RepoBuilder.Telemetry.AlertingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RepoBuilder.Telemetry.Alerting

  # The legacy global cost-threshold handler was RETIRED (issue per-project-cost-tracking)
  # and folded into a seeded global :alert Budget cap (Budget.seed_default_cap/0). Alerting
  # now only handles Oban exceptions; per-cost guardrails live in Budget.Guard.

  test "alerts on an Oban job exception" do
    log =
      capture_log(fn ->
        Alerting.handle_event(
          [:oban, :job, :exception],
          %{duration: 1},
          %{worker: "RepoBuilder.Workers.StepWorker"},
          %{}
        )
      end)

    assert log =~ "ALERT oban job exception"
  end
end
