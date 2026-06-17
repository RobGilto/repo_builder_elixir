defmodule RepoBuilder.Orchestrator.CostReportTest do
  @moduledoc """
  Tests the `report_cost` assembly (session/status/cost/cumulative tokens + context
  occupancy-% from `context_tokens`) with its ≥80% warning boundary and the unclamped
  >100% case, plus `compact_agent` dispatching `/compact` over the command path.

  `async: false` via `SessionCase` — `compact_agent` starts a Fake worker session.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp orchestrator(harness \\ "fake") do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: harness})
    orch
  end

  describe "report_cost" do
    test "assembles session/status/cost/cumulative tokens + occupancy-% (no warning below 80%)" do
      orch = orchestrator()
      {:ok, _} = Orchestrators.add_usage(orch.id, 1000, 500)
      {:ok, _} = Orchestrators.add_cost(orch.id, 0.25)

      assert {:ok, report} = Tools.call("report_cost", orch.id, %{})

      assert report["status"] == "idle"
      assert report["cost_usd"] == "0.25"
      assert report["input_tokens"] == 1000
      assert report["output_tokens"] == 500
      assert report["total_tokens"] == 1500
      assert report["context_tokens"] == 1500
      assert report["context_window"] == 200_000
      # 1500 / 200_000 = 0.75% occupancy.
      assert report["context_usage_pct"] == 0.8
      refute Map.has_key?(report, "warning")
    end

    test "occupancy uses the LATEST turn's context_tokens, not cumulative tokens" do
      orch = orchestrator()
      # Two big turns: cumulative tokens are huge, but live occupancy tracks turn 2.
      {:ok, _} = Orchestrators.add_usage(orch.id, 150_000, 10_000)
      {:ok, _} = Orchestrators.add_usage(orch.id, 1000, 500)

      assert {:ok, report} = Tools.call("report_cost", orch.id, %{})

      assert report["input_tokens"] == 151_000
      assert report["output_tokens"] == 10_500
      # Occupancy is from turn 2 only (1500), NOT the 161_500 cumulative.
      assert report["context_tokens"] == 1500
      refute Map.has_key?(report, "warning")
    end

    test "warns at >= 80% occupancy" do
      orch = orchestrator()
      {:ok, _} = Orchestrators.add_usage(orch.id, 160_000, 20_000)

      assert {:ok, report} = Tools.call("report_cost", orch.id, %{})

      # 180_000 / 200_000 = 90%.
      assert report["context_usage_pct"] == 90.0
      assert report["warning"] =~ "context usage at 90.0%"
    end

    test "reports over-window occupancy unclamped (>100%) with a warning" do
      orch = orchestrator()
      {:ok, _} = Orchestrators.add_usage(orch.id, 250_000, 0)

      assert {:ok, report} = Tools.call("report_cost", orch.id, %{})

      # 250_000 / 200_000 = 125% — never clamped.
      assert report["context_usage_pct"] == 125.0
      assert Map.has_key?(report, "warning")
    end
  end

  describe "compact_agent" do
    test "dispatches /compact to a known worker via the command path" do
      orch = orchestrator()
      name = "worker-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "fake",
          "model" => "fake-model-1"
        })

      assert {:ok, %{"status" => "dispatched", "name" => ^name}} =
               Tools.call("compact_agent", orch.id, %{"name" => name})
    end

    test "an unknown worker returns a helpful error (no crash)" do
      orch = orchestrator()

      assert {:error, _reason} =
               Tools.call("compact_agent", orch.id, %{"name" => "ghost-#{uniq()}"})
    end
  end
end
