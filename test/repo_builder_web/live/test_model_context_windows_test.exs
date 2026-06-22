defmodule RepoBuilderWeb.ModelContextWindowsTest do
  @moduledoc """
  The context-window bar (agent cards + orchestrator panel) must reflect the REAL
  maximum context window of the model assigned to that agent/orchestrator — resolved
  via `RepoBuilder.Orchestrator.ContextWindow` (config override → live/built-in catalog
  → default) — not a hardcoded 200k denominator. A `claude-sonnet-4-6` agent (1M window)
  and a `claude-opus-4-8` agent (200k window) at the SAME token occupancy must render
  different denominators AND different fill widths.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event

  defp persist(event, agent_id),
    do: {:ok, _} = Logs.persist_event(event, %{agent_id: agent_id, session_id: "s"})

  defp seed_worker(orch_id, model) do
    {:ok, agent} =
      Agents.create_worker(orch_id, %{
        name: "ctx-#{System.unique_integer([:positive])}",
        harness: "claude",
        provider: "anthropic",
        model: model
      })

    # 200_000 tokens of prompt occupancy (input only; output excluded from context size).
    persist(%Event.Usage{harness: :claude, input_tokens: 200_000, output_tokens: 1}, agent.id)
    agent
  end

  test "agent cards render each model's real window and a window-relative fill", %{conn: conn} do
    {:ok, orch} = Orchestrators.get_or_create_default()

    sonnet = seed_worker(orch.id, "claude-sonnet-4-6")
    opus = seed_worker(orch.id, "claude-opus-4-8")

    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, {:agent_created, sonnet})
    send(view.pid, {:agent_created, opus})
    _ = render(view)

    sonnet_card = render(element(view, "#agent-#{sonnet.id}"))
    opus_card = render(element(view, "#agent-#{opus.id}"))

    # Sonnet: 200k of a 1M window → denominator /1000k, bar 20%.
    assert sonnet_card =~ "200k / 1000k"
    assert sonnet_card =~ "width: 20%"

    # Opus: 200k of a 200k window → denominator /200k, bar 100%.
    assert opus_card =~ "200k / 200k"
    assert opus_card =~ "width: 100%"
  end

  test "the orchestrator panel reflects its own model's window", %{conn: conn} do
    {:ok, orch} = Orchestrators.get_or_create_default()
    # set_harness resets the model (harness switch), so assign the model afterwards.
    {:ok, _} = Orchestrators.set_harness(orch.id, "claude")
    {:ok, _} = Orchestrators.set_model(orch.id, "claude-sonnet-4-6")

    {:ok, view, _html} = live(conn, ~p"/")

    panel = render(element(view, "#command-panel"))
    assert panel =~ "/ 1000k"
  end
end
