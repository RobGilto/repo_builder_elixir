defmodule RepoBuilder.BudgetTest do
  @moduledoc """
  Context CRUD + changeset validation + unique-key + scope derivation for the durable
  budget caps (issue-budget-guardrails).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.{Cap, Scope}
  alias RepoBuilder.Projects

  describe "Scope.scopes_for/1" do
    test "always includes the global scope" do
      assert Scope.scopes_for(%{}) == [{:global, ""}]
    end

    test "adds orchestrator, workflow, and project scopes when present (string or atom keys)" do
      refs = Scope.scopes_for(%{orchestrator_id: "o1", workflow_run_id: "w1", project_id: "p1"})
      assert {:global, ""} in refs
      assert {:orchestrator, "o1"} in refs
      assert {:workflow, "w1"} in refs
      assert {:project, "p1"} in refs
    end

    test "ignores blank/nil ids" do
      assert Scope.scopes_for(%{orchestrator_id: "", workflow_run_id: nil}) == [{:global, ""}]
    end
  end

  describe "seed_project_cap/1" do
    test "seeds a live :project/:total :pause cap from budget_cap_usd" do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "proj-#{System.unique_integer([:positive])}",
          "root_path" => "/tmp/cap-proj",
          "budget_cap_usd" => "12.50"
        })

      assert {:ok, %Cap{} = cap} = Budget.seed_project_cap(project)
      assert cap.scope == :project
      assert cap.scope_id == project.id
      assert cap.period == :total
      assert cap.action == :pause
      assert Decimal.equal?(cap.limit_usd, Decimal.new("12.50"))
    end

    test "is a no-op when the project has no budget cap" do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "proj-#{System.unique_integer([:positive])}",
          "root_path" => "/tmp/nocap-proj"
        })

      assert {:ok, :none} = Budget.seed_project_cap(project)
    end
  end

  describe "upsert_cap/1 + changeset" do
    test "creates a global cap, forcing scope_id to the sentinel" do
      assert {:ok, %Cap{} = cap} =
               Budget.upsert_cap(%{
                 "scope" => "global",
                 "period" => "total",
                 "limit_usd" => "10.0",
                 "action" => "alert"
               })

      assert cap.scope == :global
      assert cap.scope_id == ""
      assert cap.action == :alert
    end

    test "requires scope_id for a non-global cap" do
      assert {:error, changeset} =
               Budget.upsert_cap(%{
                 "scope" => "orchestrator",
                 "period" => "total",
                 "limit_usd" => "5.0",
                 "action" => "pause"
               })

      assert %{scope_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects a non-positive limit and an out-of-range warn_ratio" do
      assert {:error, cs1} =
               Budget.upsert_cap(%{"scope" => "global", "limit_usd" => "0", "action" => "alert"})

      assert %{limit_usd: [_ | _]} = errors_on(cs1)

      assert {:error, cs2} =
               Budget.upsert_cap(%{
                 "scope" => "global",
                 "limit_usd" => "5",
                 "warn_ratio" => 1.5,
                 "action" => "alert"
               })

      assert %{warn_ratio: [_ | _]} = errors_on(cs2)
    end

    test "the (scope, scope_id, period) key is unique — a second insert updates in place" do
      {:ok, a} =
        Budget.upsert_cap(%{
          "scope" => "global",
          "period" => "total",
          "limit_usd" => "10",
          "action" => "alert"
        })

      {:ok, b} =
        Budget.upsert_cap(%{
          "scope" => "global",
          "period" => "total",
          "limit_usd" => "20",
          "action" => "pause"
        })

      assert a.id == b.id
      assert b.action == :pause
      assert length(Budget.list_caps()) == 1
    end
  end

  describe "caps_for_scopes/1" do
    test "returns only enabled caps matching the given scope_refs" do
      {:ok, _global} =
        Budget.upsert_cap(%{"scope" => "global", "limit_usd" => "10", "action" => "alert"})

      {:ok, _orch} =
        Budget.upsert_cap(%{
          "scope" => "orchestrator",
          "scope_id" => "o1",
          "limit_usd" => "5",
          "action" => "pause"
        })

      {:ok, disabled} =
        Budget.upsert_cap(%{
          "scope" => "workflow",
          "scope_id" => "w1",
          "limit_usd" => "3",
          "action" => "hard_stop"
        })

      {:ok, _} = Budget.update_cap(disabled, %{"enabled" => false})

      refs = [{:global, ""}, {:orchestrator, "o1"}, {:workflow, "w1"}]
      scopes = refs |> Budget.caps_for_scopes() |> Enum.map(&{&1.scope, &1.scope_id})

      assert {:global, ""} in scopes
      assert {:orchestrator, "o1"} in scopes
      refute {:workflow, "w1"} in scopes
    end

    test "an empty scope list returns no caps" do
      assert Budget.caps_for_scopes([]) == []
    end
  end

  describe "delete_cap/1" do
    test "deletes by id and reports not_found for a missing id" do
      {:ok, cap} =
        Budget.upsert_cap(%{"scope" => "global", "limit_usd" => "10", "action" => "alert"})

      assert {:ok, _} = Budget.delete_cap(cap.id)
      assert {:error, :not_found} = Budget.delete_cap(cap.id)
    end
  end

  describe "seed_default_cap/0" do
    test "seeds a global alert cap from the configured threshold, idempotently" do
      assert {:ok, %Cap{} = cap} = Budget.seed_default_cap()
      assert cap.scope == :global
      assert cap.action == :alert
      assert {:ok, :exists} = Budget.seed_default_cap()
      assert Enum.count(Budget.list_caps(), &(&1.scope == :global)) == 1
    end
  end
end
