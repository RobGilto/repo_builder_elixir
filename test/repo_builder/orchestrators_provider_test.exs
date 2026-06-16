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

  describe "per-harness orchestrator defaults" do
    test "get_or_create_default(\"claude\") seeds provider anthropic + model opus" do
      assert {:ok, orch} = Orchestrators.get_or_create_default("claude")
      assert orch.provider == "anthropic"
      assert orch.model == "opus"
    end

    test "switching to claude restores Opus; switching to pi clears the Claude-only model" do
      orch = orchestrator_fixture(%{harness: "pi", provider: "openai", model: "gpt-4o"})

      assert {:ok, claude} = Orchestrators.set_harness(orch.id, "claude")
      assert claude.harness == "claude"
      assert claude.provider == "anthropic"
      assert claude.model == "opus"

      assert {:ok, pi} = Orchestrators.set_harness(orch.id, "pi")
      assert pi.harness == "pi"
      # pi has no forced provider/model — both cleared to operator-chosen (nil).
      assert pi.provider == nil
      assert pi.model == nil
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
