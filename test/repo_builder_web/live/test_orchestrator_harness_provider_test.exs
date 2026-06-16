defmodule RepoBuilderWeb.TestOrchestratorHarnessProviderTest do
  @moduledoc """
  LiveView integration for the orchestrator harness/provider/model selectors and
  dual-harness observability parity (issue-d): the header reflects the selection,
  switching to Claude applies the anthropic/opus defaults, and a keyless Fake
  orchestrator turn both broadcasts on `console:events` AND persists to `agent_logs`
  keyed by `orchestrator_id`.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Logs, Orchestrators}

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  test "switching the harness to claude applies anthropic but selects NO model", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "claude"})

    # The orchestrator row is the source of truth: provider defaults, model is unset.
    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.harness == "claude"
    assert reloaded.provider == "anthropic"
    assert reloaded.model == nil

    # Provider reflects the default; the model select sits on its blank placeholder.
    assert has_element?(view, "#orchestrator-provider option[value=anthropic][selected]")
    assert has_element?(view, ~s(#orchestrator-model option[value=""][selected]))
  end

  test "set_provider clears the model (no auto-default); set_model updates the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "pi"})

    # Picking a provider does NOT auto-assign a model.
    view
    |> form("#orchestrator-provider-form", %{"provider" => "openai"})
    |> render_change()

    {:ok, after_provider} = Orchestrators.fetch(orch.id)
    assert after_provider.provider == "openai"
    assert after_provider.model == nil

    # The operator then explicitly chooses a model.
    view
    |> form("#orchestrator-model-form", %{"model" => "gpt-5-mini"})
    |> render_change()

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.provider == "openai"
    assert reloaded.model == "gpt-5-mini"
  end

  test "a keyless Fake orchestrator turn broadcasts AND persists under orchestrator_id", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()
    # Default test orchestrator is fake (keyless) — run a turn straight away.
    assert orch.harness == "fake"

    :ok = Dashboard.subscribe_events()

    view
    |> form("#command-form", command: "observe me")
    |> render_submit()

    # (a) The orchestrator's text streams onto the global console feed.
    assert_receive {:agent_event, agent_id, %RepoBuilder.Harness.Event.TextDelta{}}, 5_000
    assert String.starts_with?(agent_id, "orch-")

    # (b) Its events persist to agent_logs keyed by orchestrator_id (parity).
    assert eventually(fn ->
             Logs.list_recent_global(500)
             |> Enum.any?(&(&1.orchestrator_id == orch.id))
           end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end
end
