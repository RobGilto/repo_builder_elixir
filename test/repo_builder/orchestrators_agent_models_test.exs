defmodule RepoBuilder.OrchestratorAgentModelsTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrators

  describe "set_agent_model/3" do
    setup do
      {:ok, orch} =
        Orchestrators.create(%{name: "test-orch", harness: "pi", provider: "anthropic"})

      %{orch: orch}
    end

    test "writes the assigned harness/provider/model to metadata", %{orch: orch} do
      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "claude-sonnet-4-6"}

      assert {:ok, updated} = Orchestrators.set_agent_model(orch.id, "fast", attrs)

      roster = get_in(updated.metadata, ["agent_models", "fast"])
      assert roster["harness"] == "pi"
      assert roster["provider"] == "anthropic"
      assert roster["model"] == "claude-sonnet-4-6"
    end

    test "persists _updated_at as UTC ISO8601 string", %{orch: orch} do
      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "claude-sonnet-4-6"}

      assert {:ok, updated} = Orchestrators.set_agent_model(orch.id, "fast", attrs)

      updated_at = get_in(updated.metadata, ["agent_models", "fast", "_updated_at"])
      assert is_binary(updated_at)
      assert {:ok, _dt, _} = DateTime.from_iso8601(updated_at)
    end

    test "broadcasts {:orchestrator_updated, orchestrator} on the events topic", %{orch: orch} do
      :ok = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "console:events")

      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "claude-sonnet-4-6"}
      assert {:ok, updated} = Orchestrators.set_agent_model(orch.id, "fast", attrs)

      assert_receive {:orchestrator_updated, ^updated}
    end

    test "returns :error for an invalid category", %{orch: orch} do
      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "m"}
      assert {:error, :invalid_category} = Orchestrators.set_agent_model(orch.id, "bogus", attrs)
    end
  end
end
