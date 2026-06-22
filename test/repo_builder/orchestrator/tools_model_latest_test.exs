defmodule RepoBuilder.Orchestrator.ToolsModelLatestTest do
  @moduledoc """
  Integration tests for the model-resolution seam at the two orchestrator
  "selects a model" boundaries (issue resolve-spawned-worker-models): `create_agent`
  persists the resolved model on the worker row, and `configure_tier` persists +
  echoes the resolved model on the roster. Resolution happens BEFORE persistence, so
  what is stored (and later displayed/priced/spawned) is the latest of the family.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Orchestrators}
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator(harness \\ "fake") do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: harness})
    orch
  end

  describe "create_agent persists the resolved (latest) model" do
    test "a concrete claude id is stored as its family alias" do
      orch = orchestrator()
      name = "worker-#{uniq()}"

      assert {:ok, result} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "claude",
                 "model" => "claude-sonnet-4-5"
               })

      assert result["model"] == "sonnet"
      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.model == "sonnet"
    end

    test "opus and haiku concrete ids resolve to their aliases" do
      orch = orchestrator()

      assert {:ok, %{"model" => "opus"}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "w-opus-#{uniq()}",
                 "harness" => "claude",
                 "model" => "claude-opus-4-5"
               })

      assert {:ok, %{"model" => "haiku"}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "w-haiku-#{uniq()}",
                 "harness" => "claude",
                 "model" => "claude-haiku-4-5"
               })
    end

    test "a pi model with no catalog sibling passes through unchanged" do
      # Test registry: pi openai => ["gpt-5", "gpt-5-mini"]; gpt-5-mini has no sibling
      # of its stem, so resolution is a no-op (and never cross-upgrades to gpt-5).
      orch = orchestrator("pi")
      name = "w-pi-#{uniq()}"

      assert {:ok, %{"model" => "gpt-5-mini"}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "pi",
                 "provider" => "openai",
                 "model" => "gpt-5-mini"
               })

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.model == "gpt-5-mini"
    end
  end

  describe "configure_tier persists + echoes the resolved (latest) model" do
    test "a concrete claude id stores the family alias on the roster and returns it" do
      orch = orchestrator()

      assert {:ok, result} =
               Tools.call("configure_tier", orch.id, %{
                 "category" => "heavy",
                 "harness" => "claude",
                 "model" => "claude-opus-4-5"
               })

      assert result["model"] == "opus"

      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      roster = Orchestrators.agent_models(reloaded)
      assert get_in(roster, ["heavy", "model"]) == "opus"
    end

    test "a pi model with no catalog sibling is stored unchanged" do
      orch = orchestrator("pi")

      assert {:ok, %{"model" => "gpt-5-mini"}} =
               Tools.call("configure_tier", orch.id, %{
                 "category" => "fast",
                 "harness" => "pi",
                 "provider" => "openai",
                 "model" => "gpt-5-mini"
               })

      {:ok, reloaded} = Orchestrators.fetch(orch.id)
      assert get_in(Orchestrators.agent_models(reloaded), ["fast", "model"]) == "gpt-5-mini"
    end
  end
end
