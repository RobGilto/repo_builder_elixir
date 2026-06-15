defmodule RepoBuilder.AgentsTest do
  @moduledoc """
  Context unit tests for `RepoBuilder.Agents` covering the agent CRUD surface the
  console drives: the new `model`/`system_prompt` fields, soft-archive via
  `archive_agent/1`, and the `archived` list filtering (BUILD_PROMPT.md §8).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Agent

  defp agent_fixture(attrs \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        Map.merge(
          %{
            name: "agent-#{System.unique_integer([:positive])}",
            harness: "claude",
            provider: :anthropic
          },
          attrs
        )
      )

    agent
  end

  describe "create_agent/1 with the new optional fields" do
    test "accepts model and system_prompt and defaults archived to false" do
      agent =
        agent_fixture(%{model: "claude-opus-4-8", system_prompt: "Be terse."})

      assert agent.model == "claude-opus-4-8"
      assert agent.system_prompt == "Be terse."
      assert agent.archived == false
    end

    test "model and system_prompt are optional (omitting them is valid)" do
      agent = agent_fixture()
      assert agent.model == nil
      assert agent.system_prompt == nil
    end
  end

  describe "update_agent/2" do
    test "persists model and system_prompt changes" do
      agent = agent_fixture()

      {:ok, updated} =
        Agents.update_agent(agent, %{model: "gpt-5", system_prompt: "Plan first."})

      assert updated.model == "gpt-5"
      assert updated.system_prompt == "Plan first."
    end
  end

  describe "archive_agent/1 + list filtering" do
    test "archive_agent/1 flips archived and excludes it from the default list" do
      agent = agent_fixture()
      assert Enum.any?(Agents.list_agents(), &(&1.id == agent.id))

      {:ok, archived} = Agents.archive_agent(agent)
      assert archived.archived == true

      refute Enum.any?(Agents.list_agents(), &(&1.id == agent.id))
    end

    test "list_agents(include_archived: true) includes archived agents" do
      agent = agent_fixture()
      {:ok, _archived} = Agents.archive_agent(agent)

      assert Enum.any?(
               Agents.list_agents(include_archived: true),
               &(&1.id == agent.id)
             )
    end

    test "archive preserves the row (soft-delete, not hard-delete)" do
      agent = agent_fixture()
      {:ok, _archived} = Agents.archive_agent(agent)

      assert %Agent{archived: true} = Agents.get_agent(agent.id)
    end
  end

  describe "changeset/2 validations on the new fields" do
    test "rejects an over-long system_prompt" do
      {:error, changeset} =
        Agents.create_agent(%{
          name: "too-long-#{System.unique_integer([:positive])}",
          harness: "claude",
          provider: :anthropic,
          system_prompt: String.duplicate("x", 20_001)
        })

      assert %{system_prompt: [_ | _]} = errors_on(changeset)
    end
  end
end
