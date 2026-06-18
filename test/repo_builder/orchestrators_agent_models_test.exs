defmodule RepoBuilder.OrchestratorAgentModelsTest do
  # async: false because the lost-update regression test spawns writer Tasks that
  # cross process boundaries and must share this test's DB connection (shared
  # sandbox mode), which is incompatible with concurrent async tests.
  use RepoBuilder.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
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

    test "returns {:error, :not_found} for an unknown orchestrator id" do
      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "m"}

      assert {:error, :not_found} =
               Orchestrators.set_agent_model(Ecto.UUID.generate(), "fast", attrs)
    end
  end

  describe "set_agent_model/3 accumulation (no lost updates)" do
    setup do
      {:ok, orch} =
        Orchestrators.create(%{name: "accum-orch", harness: "claude", provider: "anthropic"})

      %{orch: orch}
    end

    @models %{
      "fast" => "claude-haiku-4-5",
      "main" => "claude-sonnet-4-5",
      "heavy" => "claude-opus-4-5",
      "leader" => "claude-opus-4-5"
    }

    test "four successive writes leave all four tiers present", %{orch: orch} do
      for {category, model} <- @models do
        assert {:ok, _} =
                 Orchestrators.set_agent_model(orch.id, category, %{
                   "harness" => "claude",
                   "provider" => "anthropic",
                   "model" => model
                 })
      end

      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      roster = Orchestrators.agent_models(reloaded)

      assert map_size(roster) == 4

      for {category, model} <- @models do
        assert get_in(roster, [category, "model"]) == model
      end
    end

    test "four CONCURRENT writes accumulate without lost updates", %{orch: orch} do
      # The four writer Tasks run in separate processes; share this test's sandbox
      # connection so their FOR UPDATE-serialized transactions are visible here.
      Sandbox.mode(RepoBuilder.Repo, {:shared, self()})

      @models
      |> Task.async_stream(
        fn {category, model} ->
          Orchestrators.set_agent_model(orch.id, category, %{
            "harness" => "claude",
            "provider" => "anthropic",
            "model" => model
          })
        end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Stream.run()

      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      roster = Orchestrators.agent_models(reloaded)

      assert map_size(roster) == 4

      for {category, model} <- @models do
        assert get_in(roster, [category, "model"]) == model
      end
    end
  end
end
