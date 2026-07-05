defmodule RepoBuilder.Orchestrator.Tools.AgentOpsIsolationTest do
  @moduledoc """
  Worker isolation resolution matrix (worktree-panel-and-gc plan): explicit
  per-worker arg → bound project's isolation_mode → configured platform default
  (ships :worktree) — plus the `create_agent` tool's up-front validation of the
  `isolation` arg and the new-Project schema default.

  `async: false` — the platform default is process-global app env; DataCase because
  the `create_agent` tool chain touches the DB before the validation under test.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project

  defp with_default(mode, fun) do
    previous = Application.get_env(:repo_builder, :worktree, [])

    Application.put_env(
      :repo_builder,
      :worktree,
      Keyword.put(previous, :worker_isolation_default, mode)
    )

    try do
      fun.()
    after
      Application.put_env(:repo_builder, :worktree, previous)
    end
  end

  describe "Projects.resolve_worker_isolation/2" do
    test "the bound project's mode wins over the platform default" do
      assert Projects.resolve_worker_isolation(%{}, :worktree) == :worktree
      # A stored :direct is an explicit operator choice — the default never overrides it.
      assert Projects.resolve_worker_isolation(%{}, :direct) == :direct
    end

    test "a nil project mode falls to the configured platform default (:worktree)" do
      assert Projects.resolve_worker_isolation(%{}, nil) == :worktree
      assert Projects.resolve_worker_isolation(nil, nil) == :worktree
    end

    test "a :direct platform default is respected for unscoped workers" do
      with_default(:direct, fn ->
        assert Projects.resolve_worker_isolation(%{}, nil) == :direct
        # ...but still loses to a project's explicit :worktree.
        assert Projects.resolve_worker_isolation(%{}, :worktree) == :worktree
      end)
    end

    test "an explicit worker config arg beats both project mode and default" do
      assert Projects.resolve_worker_isolation(%{"isolation" => "direct"}, :worktree) == :direct

      assert Projects.resolve_worker_isolation(%{"isolation" => "worktree"}, :direct) ==
               :worktree

      with_default(:direct, fn ->
        assert Projects.resolve_worker_isolation(%{"isolation" => "worktree"}, nil) == :worktree
      end)
    end
  end

  describe "create_agent isolation arg validation" do
    test "an invalid isolation value is rejected up front" do
      assert {:error, reason} =
               Tools.call("create_agent", Ecto.UUID.generate(), %{
                 "name" => "iso-test",
                 "isolation" => "chroot"
               })

      assert reason =~ ~s(isolation must be "direct" or "worktree")
    end
  end

  test "a new Project struct defaults to :worktree isolation" do
    assert %Project{}.isolation_mode == :worktree
  end

  describe "create_agent worktree_run_id takeover key (issue worktree-takeover)" do
    alias RepoBuilder.Agents
    alias RepoBuilder.Orchestrators

    defp orch! do
      {:ok, orch} =
        Orchestrators.create(%{
          name: "orch-#{System.unique_integer([:positive])}",
          harness: "fake"
        })

      orch
    end

    test "a valid takeover key is persisted on the worker config" do
      orch = orch!()
      name = "tk-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{
                 "name" => name,
                 "harness" => "fake",
                 "worktree_run_id" => "abc-123.def_4"
               })

      {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.config["worktree_run_id"] == "abc-123.def_4"
    end

    test "a path-traversal key is rejected up front" do
      assert {:error, reason} =
               Tools.call("create_agent", Ecto.UUID.generate(), %{
                 "name" => "evil",
                 "worktree_run_id" => "../evil"
               })

      assert reason =~ "worktree_run_id"
    end

    test "an empty key is rejected up front" do
      assert {:error, reason} =
               Tools.call("create_agent", Ecto.UUID.generate(), %{
                 "name" => "blank",
                 "worktree_run_id" => ""
               })

      assert reason =~ "worktree_run_id"
    end

    test "an omitted key leaves the worker config without the field" do
      orch = orch!()
      name = "tk-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      refute Map.has_key?(worker.config, "worktree_run_id")
    end
  end
end
