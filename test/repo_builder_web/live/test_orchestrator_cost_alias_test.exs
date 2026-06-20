defmodule RepoBuilderWeb.OrchestratorCostAliasTest do
  @moduledoc """
  Regression test for issue log-7700: a Claude orchestrator running on a model ALIAS
  (`opus`/`sonnet`/`haiku`) must still show a live `~$` cost estimate in the command
  panel as context fills. The price catalog is keyed by canonical family IDs, so before
  the fix the alias missed the lookup, `estimated_cost_usd` was nil, and the badge showed
  `—` for the whole in-flight turn. After the fix the alias is canonicalized for pricing.

  Drives the orchestrator-owned `{:agent_event, "orch-…", %Event.Usage{}}` PubSub seam
  (`ConsoleLive` routes any `"orch-"`-prefixed agent_id into `:orchestrator_est_cost`).
  The event is built through the REAL Claude harness path, so it carries a non-nil estimate
  only when the alias resolves — the test therefore fails before the fix, passes after.

  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.{Claude, Event}

  # The live model is the ALIAS; the catalog is keyed by the CANONICAL family ID only.
  @alias_model "opus"
  @canonical "claude-opus-4-8"
  @ctx %{harness: :claude, model: @alias_model, price_table: %{@canonical => 30.0}}

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  defp alias_usage_event do
    frame = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 0}
      }
    }

    {:ok, events} = Claude.normalize(frame, @ctx)
    Enum.find(events, &match?(%Event.Usage{}, &1))
  end

  test "the command-panel cost badge shows a ~$ estimate for an alias model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    usage = alias_usage_event()

    # The alias must canonicalize for pricing, so the harness already derived a non-nil
    # estimate before broadcast (nil before the fix → badge stays `—`).
    assert usage.estimated_cost_usd == 30.0

    # Orchestrator-owned events broadcast under a synthetic `"orch-<id>-<n>"` agent_id.
    Dashboard.broadcast_event("orch-#{System.unique_integer([:positive])}-1", usage)

    assert wait_until(fn -> render(element(view, "#command-panel")) =~ "~$" end),
           "the command-panel cost badge must render a live ~$ estimate for an alias model"
  end
end
