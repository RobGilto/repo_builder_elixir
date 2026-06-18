defmodule RepoBuilder.OrchestratorsTimezoneTest do
  @moduledoc """
  Context tests for the persisted display timezone (issue-a):
  `Orchestrators.timezone/1` (default + read-back) and `set_timezone/2` (valid persist +
  broadcast, invalid rejection, atomic no-clobber of sibling `metadata` keys).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator_fixture(attrs \\ %{}) do
    {:ok, orch} =
      Orchestrators.create(Map.merge(%{name: "tz-orch-#{uniq()}", harness: "claude"}, attrs))

    orch
  end

  describe "timezone/1" do
    test "defaults to UTC for a fresh orchestrator" do
      assert Orchestrators.timezone(orchestrator_fixture()) == "UTC"
    end

    test "returns the stored value after a set" do
      orch = orchestrator_fixture()
      {:ok, _} = Orchestrators.set_timezone(orch.id, "Australia/Sydney")
      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      assert Orchestrators.timezone(reloaded) == "Australia/Sydney"
    end

    test "falls back to UTC when the stored value is no longer valid" do
      # timezone/1 is pure on the struct; a stale/invalid stored zone reads as UTC.
      orch = %Orchestrator{metadata: %{"timezone" => "Mars/Olympus"}}
      assert Orchestrators.timezone(orch) == "UTC"
    end
  end

  describe "set_timezone/2" do
    test "persists a valid zone and returns {:ok, orchestrator}" do
      orch = orchestrator_fixture()
      assert {:ok, updated} = Orchestrators.set_timezone(orch.id, "America/New_York")
      assert updated.metadata["timezone"] == "America/New_York"
    end

    test "broadcasts {:orchestrator_updated, orchestrator} on the events topic" do
      :ok = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "console:events")
      orch = orchestrator_fixture()

      assert {:ok, updated} = Orchestrators.set_timezone(orch.id, "Asia/Tokyo")
      assert_receive {:orchestrator_updated, ^updated}
    end

    test "rejects an invalid zone without mutating metadata" do
      orch = orchestrator_fixture()
      assert {:error, :invalid_timezone} = Orchestrators.set_timezone(orch.id, "Mars/Olympus")
      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      refute Map.has_key?(reloaded.metadata, "timezone")
    end

    test "returns :not_found for an unknown orchestrator id" do
      assert {:error, :not_found} = Orchestrators.set_timezone(Ecto.UUID.generate(), "UTC")
    end

    test "preserves a pre-existing sibling metadata key (atomic, no clobber)" do
      orch = orchestrator_fixture()

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "fast", %{
          "harness" => "claude",
          "provider" => "anthropic",
          "model" => "claude-haiku-4-5"
        })

      assert {:ok, updated} = Orchestrators.set_timezone(orch.id, "Europe/London")

      # The timezone write must not drop the agent_models roster.
      assert updated.metadata["timezone"] == "Europe/London"
      assert get_in(updated.metadata, ["agent_models", "fast", "model"]) == "claude-haiku-4-5"
    end
  end
end
