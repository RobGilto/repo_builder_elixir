defmodule RepoBuilderWeb.AgentModelsModalTest do
  @moduledoc """
  Integration tests for the agent-models modal live-state fix:
  - PubSub broadcast updates agent_model_rows in an open LiveView
  - Modal UI reflects an externally-changed tier
  - N/4 configured count is correct
  - open_agent_models event re-fetches from DB
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  describe "agent_models_modal live-state" do
    test "LiveView updates agent_model_rows when it receives {:orchestrator_updated}", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id
      attrs = %{"harness" => "pi", "provider" => "anthropic", "model" => "claude-sonnet-4-6"}
      {:ok, updated} = Orchestrators.set_agent_model(orchestrator_id, "fast", attrs)

      send(view.pid, {:orchestrator_updated, updated})
      _ = render(view)

      rows = :sys.get_state(view.pid).socket.assigns.agent_model_rows
      fast = Enum.find(rows, &(&1.category == "fast"))
      assert fast.model == "claude-sonnet-4-6"
    end

    test "configured_tier_count is correct after external mutation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      for {cat, model} <- [{"fast", "m1"}, {"main", "m2"}] do
        {:ok, updated} =
          Orchestrators.set_agent_model(orchestrator_id, cat, %{
            "harness" => "pi",
            "provider" => "anthropic",
            "model" => model
          })

        send(view.pid, {:orchestrator_updated, updated})
        _ = render(view)
      end

      count = :sys.get_state(view.pid).socket.assigns.configured_tier_count
      assert count == 2
    end

    test "modal shows N/4 configured summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      {:ok, updated} =
        Orchestrators.set_agent_model(orchestrator_id, "fast", %{
          "harness" => "pi",
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-6"
        })

      send(view.pid, {:orchestrator_updated, updated})
      _ = render(view)

      assert has_element?(view, "#agent-models-modal", "1/4 configured")
    end

    test "open_agent_models event re-fetches from DB", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id

      # Mutate directly without sending a broadcast — simulates out-of-band change
      # that happened before this session opened (only the DB has the new value).
      {:ok, _} =
        Orchestrators.set_agent_model(orchestrator_id, "heavy", %{
          "harness" => "pi",
          "provider" => "anthropic",
          "model" => "some-model"
        })

      # Trigger the "Agents…" button server event (JS.push side)
      view |> element("#agent-models-toggle") |> render_click()
      _ = render(view)

      rows = :sys.get_state(view.pid).socket.assigns.agent_model_rows
      heavy = Enum.find(rows, &(&1.category == "heavy"))
      assert heavy.model == "some-model"
    end
  end

  describe "configured_tier_count/1" do
    test "counts rows with non-blank models" do
      rows = [
        %{category: "fast", model: "m1"},
        %{category: "main", model: nil},
        %{category: "heavy", model: ""},
        %{category: "leader", model: "m4"}
      ]

      assert RepoBuilderWeb.ConsoleLive.configured_tier_count(rows) == 2
    end
  end
end
