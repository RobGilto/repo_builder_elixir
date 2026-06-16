defmodule RepoBuilder.OrchestratorsProviderTest do
  @moduledoc """
  Provider/model context behaviour (issue-d): open `provider` identity, the two
  setters, and per-harness orchestrator-default application on create/switch.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator_fixture(attrs \\ %{}) do
    {:ok, orch} =
      Orchestrators.create(Map.merge(%{name: "orch-#{uniq()}", harness: "claude"}, attrs))

    orch
  end

  describe "set_provider/2 and set_model/2" do
    test "round-trip an open provider string and a model" do
      orch = orchestrator_fixture()

      assert {:ok, updated} = Orchestrators.set_provider(orch.id, "groq")
      assert updated.provider == "groq"

      assert {:ok, updated2} = Orchestrators.set_model(orch.id, "glm-4.6")
      assert updated2.model == "glm-4.6"
    end

    test "nil clears the provider" do
      orch = orchestrator_fixture(%{provider: "openai"})
      assert {:ok, cleared} = Orchestrators.set_provider(orch.id, nil)
      assert cleared.provider == nil
    end

    test "a missing orchestrator returns {:error, :not_found}" do
      assert {:error, :not_found} = Orchestrators.set_provider(Ecto.UUID.generate(), "openai")
    end
  end

  describe "per-harness orchestrator defaults (no auto model)" do
    test "get_or_create_default(\"claude\") seeds provider anthropic but NO model" do
      assert {:ok, orch} = Orchestrators.get_or_create_default("claude")
      assert orch.provider == "anthropic"
      # No model is auto-assigned — the operator must pick one explicitly.
      assert orch.model == nil
    end

    test "switching harness applies the provider default and clears the model" do
      orch = orchestrator_fixture(%{harness: "pi", provider: "openai", model: "gpt-4o"})

      assert {:ok, claude} = Orchestrators.set_harness(orch.id, "claude")
      assert claude.harness == "claude"
      assert claude.provider == "anthropic"
      assert claude.model == nil

      assert {:ok, pi} = Orchestrators.set_harness(orch.id, "pi")
      assert pi.harness == "pi"
      # pi has no forced provider/model — both cleared to operator-chosen (nil).
      assert pi.provider == nil
      assert pi.model == nil
    end
  end

  describe "model reset, recents, and session hygiene" do
    test "set_provider clears the model (no auto-default) and the session" do
      orch =
        orchestrator_fixture(%{
          harness: "claude",
          provider: "anthropic",
          model: "sonnet",
          session_id: "sess-x"
        })

      assert {:ok, updated} = Orchestrators.set_provider(orch.id, "anthropic")
      # No model is auto-picked; the operator must choose one.
      assert updated.model == nil
      assert updated.session_id == nil
    end

    test "set_model records per-provider recents (most-recent first, deduped)" do
      orch = orchestrator_fixture(%{harness: "claude", provider: "anthropic"})

      {:ok, _} = Orchestrators.set_model(orch.id, "sonnet")
      {:ok, _} = Orchestrators.set_model(orch.id, "haiku")
      {:ok, again} = Orchestrators.set_model(orch.id, "sonnet")

      assert Orchestrators.recent_models(again, "anthropic") == ["sonnet", "haiku"]
      # Recents are scoped to the provider.
      assert Orchestrators.recent_models(again, "openai") == []
    end

    test "switching harness clears the stale resumable session id" do
      orch = orchestrator_fixture(%{harness: "fake", session_id: "fake-orchestrator"})

      assert {:ok, switched} = Orchestrators.set_harness(orch.id, "claude")
      assert switched.session_id == nil
    end
  end

  describe "agent model roster" do
    test "agent_categories are fast/main/heavy/leader" do
      assert Orchestrators.agent_categories() == ["fast", "main", "heavy", "leader"]
    end

    test "set_agent_model assigns a category and agent_models reads it back" do
      orch = orchestrator_fixture()

      attrs = %{"harness" => "pi", "provider" => "minimax", "model" => "MiniMax-M3"}
      assert {:ok, updated} = Orchestrators.set_agent_model(orch.id, "heavy", attrs)
      assert Orchestrators.agent_models(updated)["heavy"] == attrs
    end

    test "a blank model is stored as nil (category unassigned)" do
      orch = orchestrator_fixture()

      assert {:ok, updated} =
               Orchestrators.set_agent_model(orch.id, "fast", %{"harness" => "pi", "model" => ""})

      assert Orchestrators.agent_models(updated)["fast"]["model"] == nil
    end

    test "an unknown category is rejected" do
      orch = orchestrator_fixture()
      assert {:error, :invalid_category} = Orchestrators.set_agent_model(orch.id, "turbo", %{})
    end
  end

  describe "open provider identity at the write boundary" do
    test "an arbitrary provider string is accepted (not a closed enum)" do
      assert {:ok, orch} =
               Orchestrators.create(%{name: "o-#{uniq()}", harness: "pi", provider: "zai"})

      assert orch.provider == "zai"
    end

    test "an unregistered harness is rejected by the changeset" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Orchestrators.create(%{name: "o-#{uniq()}", harness: "nope"})

      assert "is not a registered harness" in errors_on(cs).harness
    end
  end
end
