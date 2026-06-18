defmodule RepoBuilderWeb.AgentModelsModalReflectsConfigTest do
  @moduledoc """
  Integration test guarding the two defects behind "the modal does not reflect the
  orchestrator's assigned tiers":

  - Fix #1 (atomic write): seeding all four tiers via the context accumulates (4/4),
    proving `set_agent_model/3` no longer loses concurrent/successive updates.
  - Fix #2 (display): each tier's concrete Anthropic id — absent from the `claude`
    registry's curated tier-alias list (`opus`/`sonnet`/`haiku`) — is still rendered
    as the `selected` model option rather than the blank `no model` fallback.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  @tiers %{
    "fast" => "claude-haiku-4-5",
    "main" => "claude-sonnet-4-5",
    "heavy" => "claude-opus-4-5",
    "leader" => "claude-opus-4-5"
  }

  describe "agent-models modal reflects orchestrator-assigned tiers" do
    test "renders 4/4 configured with each assigned model selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      # Seed all four tiers via the context (exercises Fix #1's accumulation).
      for {category, model} <- @tiers do
        {:ok, updated} =
          Orchestrators.set_agent_model(orchestrator_id, category, %{
            "harness" => "claude",
            "provider" => "anthropic",
            "model" => model
          })

        send(view.pid, {:orchestrator_updated, updated})
      end

      _ = render(view)

      # Fix #1: all four tiers survived the writes.
      assert has_element?(view, "#agent-models-modal", "4/4 configured")

      # Fix #2: the assigned concrete id is the selected option for every tier, even
      # though the registry curates only the abstract aliases for claude/anthropic.
      for {category, model} <- @tiers do
        assert has_element?(
                 view,
                 "#agent-model-#{category} select[name=model] option[selected]",
                 model
               )

        # Negative guard: the blank "no model" fallback is NOT selected for a
        # configured tier (its only selected option is the assigned id).
        refute has_element?(
                 view,
                 "#agent-model-#{category} select[name=model] option[selected]",
                 "no model (won't spawn)"
               )
      end
    end
  end
end
