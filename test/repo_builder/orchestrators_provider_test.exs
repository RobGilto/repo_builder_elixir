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

  describe "system prompt + mode (set/reset/default)" do
    test "set_system_prompt persists trimmed text and the chosen mode" do
      orch = orchestrator_fixture()

      assert {:ok, updated} = Orchestrators.set_system_prompt(orch.id, "  Be terse.  ", :replace)
      assert updated.system_prompt == "Be terse."
      assert updated.system_prompt_mode == :replace
    end

    test "blank/whitespace-only text persists as nil (falls back to default at spawn)" do
      orch = orchestrator_fixture(%{system_prompt: "old"})

      assert {:ok, updated} = Orchestrators.set_system_prompt(orch.id, "   ", :append)
      assert updated.system_prompt == nil
      assert updated.system_prompt_mode == :append
    end

    test "the default mode is :append for a freshly created orchestrator" do
      orch = orchestrator_fixture()
      assert orch.system_prompt_mode == :append
    end

    test "reset_system_prompt clears the override and restores :append" do
      orch = orchestrator_fixture()
      {:ok, _} = Orchestrators.set_system_prompt(orch.id, "custom", :replace)

      assert {:ok, reset} = Orchestrators.reset_system_prompt(orch.id)
      assert reset.system_prompt == nil
      assert reset.system_prompt_mode == :append

      # Idempotent: resetting an already-default orchestrator still succeeds.
      assert {:ok, _} = Orchestrators.reset_system_prompt(orch.id)
    end

    test "an unknown orchestrator id returns {:error, :not_found}" do
      assert {:error, :not_found} =
               Orchestrators.set_system_prompt(Ecto.UUID.generate(), "x", :append)

      assert {:error, :not_found} = Orchestrators.reset_system_prompt(Ecto.UUID.generate())
    end

    test "default_system_prompt returns a non-empty generated prompt mentioning a tool" do
      orch = orchestrator_fixture()
      prompt = Orchestrators.default_system_prompt(orch)

      assert is_binary(prompt) and prompt != ""
      assert prompt =~ "create_agent"
    end
  end

  describe "reasoning effort (harness-blind)" do
    test "set_reasoning_effort persists each level" do
      orch = orchestrator_fixture()

      assert {:ok, high} = Orchestrators.set_reasoning_effort(orch.id, :high)
      assert high.reasoning_effort == :high

      assert {:ok, maxed} = Orchestrators.set_reasoning_effort(orch.id, :max)
      assert maxed.reasoning_effort == :max

      assert {:ok, off} = Orchestrators.set_reasoning_effort(orch.id, :off)
      assert off.reasoning_effort == :off
    end

    test "the default for a freshly created orchestrator is :default" do
      orch = orchestrator_fixture()
      assert orch.reasoning_effort == :default
    end

    test "an unknown orchestrator id returns {:error, :not_found}" do
      assert {:error, :not_found} =
               Orchestrators.set_reasoning_effort(Ecto.UUID.generate(), :high)
    end

    test "reasoning_efforts/0 lists all six levels with :default first" do
      assert Orchestrators.reasoning_efforts() ==
               [:default, :off, :low, :medium, :high, :max]
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

  describe "add_usage/3 and token_totals/1" do
    test "fresh orchestrator has zero token totals" do
      orch = orchestrator_fixture()
      assert Orchestrators.token_totals(orch) == %{input: 0, output: 0, total: 0, context: 0}
    end

    test "accumulates cumulative input/output but OVERWRITES context_tokens per turn" do
      orch = orchestrator_fixture()

      assert {:ok, after1} = Orchestrators.add_usage(orch.id, 1000, 500)
      assert after1.input_tokens == 1000
      assert after1.output_tokens == 500
      # Latest-turn occupancy = this turn's input+output.
      assert after1.context_tokens == 1500

      assert {:ok, after2} = Orchestrators.add_usage(orch.id, 200, 300)
      # Cumulative counters SUM both turns...
      assert after2.input_tokens == 1200
      assert after2.output_tokens == 800
      # ...but context_tokens reflects ONLY the 2nd turn (occupancy, not a sum).
      assert after2.context_tokens == 500

      assert Orchestrators.token_totals(after2) == %{
               input: 1200,
               output: 800,
               total: 2000,
               context: 500
             }
    end

    test "nil/zero token args are no-op-safe" do
      orch = orchestrator_fixture()

      assert {:ok, updated} = Orchestrators.add_usage(orch.id, nil, nil)
      assert updated.input_tokens == 0
      assert updated.output_tokens == 0
      assert updated.context_tokens == 0
    end

    test "a missing orchestrator returns {:error, :not_found}" do
      assert {:error, :not_found} = Orchestrators.add_usage(Ecto.UUID.generate(), 10, 10)
    end
  end
end
