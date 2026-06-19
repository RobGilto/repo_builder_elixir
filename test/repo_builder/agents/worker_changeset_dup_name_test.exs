defmodule RepoBuilder.Agents.WorkerChangesetDupNameTest do
  @moduledoc """
  Proves a duplicate `(orchestrator_id, name)` worker insert surfaces the violation on
  `:name` (not the misleading `:orchestrator_id`), so the orchestrator tool boundary
  returns an actionable "duplicate or invalid name" the LLM can self-correct on
  (issue-doing-adw-a). Per-orchestrator scoping still allows the same name across
  different orchestrators.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Orchestrators}
  alias RepoBuilder.Orchestrator.Tools

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, o} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    o
  end

  defp worker_params(name), do: %{"name" => name, "harness" => "fake", "provider" => "anthropic"}

  test "a duplicate name under the same orchestrator reports the error on :name" do
    o = orchestrator()
    assert {:ok, _} = Agents.create_worker(o.id, worker_params("dupe"))

    assert {:error, changeset} = Agents.create_worker(o.id, worker_params("dupe"))
    errors = Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)

    assert Map.has_key?(errors, :name)
    refute Map.has_key?(errors, :orchestrator_id)
  end

  test "the same worker name is allowed under different orchestrators" do
    o1 = orchestrator()
    o2 = orchestrator()

    assert {:ok, _} = Agents.create_worker(o1.id, worker_params("shared"))
    assert {:ok, _} = Agents.create_worker(o2.id, worker_params("shared"))
  end

  test "the create_agent tool boundary returns the friendly duplicate-name message" do
    o = orchestrator()
    args = %{"name" => "tool-dupe", "harness" => "fake", "provider" => "anthropic"}

    assert {:ok, _} = Tools.call("create_agent", o.id, args)
    assert {:error, "duplicate or invalid name"} = Tools.call("create_agent", o.id, args)
  end
end
