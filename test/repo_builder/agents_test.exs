defmodule RepoBuilder.AgentsTest do
  @moduledoc """
  Context tests for soft-archive (re-integrated from the db130314 agent-CRUD branch):
  `archive_agent/1` flips `archived`, the default `list_agents/0` excludes archived
  agents, and `list_agents(include_archived: true)` includes them. Archive is a
  soft-delete — the row survives (BUILD_PROMPT.md §8).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Agent

  defp agent(name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "fake", provider: :anthropic})
    agent
  end

  defp uniq, do: System.unique_integer([:positive])

  describe "create_agent/1" do
    test "defaults archived to false" do
      assert agent("a-#{uniq()}").archived == false
    end
  end

  describe "archive_agent/1 + list filtering" do
    test "flips archived and excludes it from the default list" do
      a = agent("a-#{uniq()}")
      assert Enum.any?(Agents.list_agents(), &(&1.id == a.id))

      {:ok, archived} = Agents.archive_agent(a)
      assert archived.archived == true
      refute Enum.any?(Agents.list_agents(), &(&1.id == a.id))
    end

    test "list_agents(include_archived: true) includes archived agents" do
      a = agent("a-#{uniq()}")
      {:ok, _archived} = Agents.archive_agent(a)

      assert Enum.any?(Agents.list_agents(include_archived: true), &(&1.id == a.id))
    end

    test "archive is a soft-delete — the row is preserved" do
      a = agent("a-#{uniq()}")
      {:ok, _archived} = Agents.archive_agent(a)

      assert %Agent{archived: true} = Agents.get_agent(a.id)
    end
  end
end
