defmodule RepoBuilderWeb.AgentModelCascadePersistTest do
  @moduledoc """
  Regression test for the agent-models cascade clobber bug: a no-op `change` event
  on a tier's harness `<select>` (LiveView reconnect reconciliation, or re-picking the
  same option) must NOT wipe the tier's saved provider/model. A genuine harness change
  to a *different* harness must still clear the now-invalid downstream selections.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  describe "set_agent_model cascade" do
    test "a no-op harness change preserves the stored provider+model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      {:ok, updated} =
        Orchestrators.set_agent_model(orchestrator_id, "main", %{
          "harness" => "pi",
          "provider" => "zai",
          "model" => "glm-5.2"
        })

      # Seed the open LiveView's agent_model_rows from the persisted roster.
      send(view.pid, {:orchestrator_updated, updated})
      _ = render(view)

      # Fire a spurious harness `change` carrying the *same* harness and blank
      # downstream fields — exactly what the browser emits on reconnect reconciliation.
      view
      |> element("#agent-model-main")
      |> render_change(%{
        "_target" => ["harness"],
        "category" => "main",
        "harness" => "pi",
        "provider" => "",
        "model" => ""
      })

      {:ok, orch} = Orchestrators.fetch(orchestrator_id)
      main = Orchestrators.agent_models(orch)["main"]
      assert main["harness"] == "pi"
      assert main["provider"] == "zai"
      assert main["model"] == "glm-5.2"
    end

    test "a genuine harness change to a different harness clears provider+model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      {:ok, updated} =
        Orchestrators.set_agent_model(orchestrator_id, "main", %{
          "harness" => "pi",
          "provider" => "zai",
          "model" => "glm-5.2"
        })

      send(view.pid, {:orchestrator_updated, updated})
      _ = render(view)

      view
      |> element("#agent-model-main")
      |> render_change(%{
        "_target" => ["harness"],
        "category" => "main",
        "harness" => "claude",
        "provider" => "zai",
        "model" => "glm-5.2"
      })

      {:ok, orch} = Orchestrators.fetch(orchestrator_id)
      main = Orchestrators.agent_models(orch)["main"]
      assert main["harness"] == "claude"
      assert main["provider"] == nil
      assert main["model"] == nil
    end
  end
end
