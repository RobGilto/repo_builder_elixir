defmodule RepoBuilderWeb.CostBadgeCacheEstimateTest do
  @moduledoc """
  Proves the live cost badge estimate is cache-aware (issue cost-adw-estimate): a Claude
  `Event.Usage` whose prompt is served largely from cache (small `input_tokens`, large
  `cache_read`) must render a `~$` estimate that reflects the cache contribution — strictly
  greater than the input+output-only figure. Fails before the cache-aware `Pricing.derive`,
  passes after.

  Drives the `{:agent_event, agent_id, %Event.Usage{}}` PubSub seam `ConsoleLive` handles.
  `async: false` so the shared Ecto sandbox reaches the connected LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Harness.{Claude, Event}

  @model "claude-opus-4-8"
  # Price the model so input/output and cache tokens derive a clean positive estimate.
  @ctx %{harness: :claude, model: @model, price_table: %{@model => 30.0}}

  defp uniq_name, do: "cache-cost-agent-#{System.unique_integer([:positive])}"

  defp create_agent(view, name) do
    {:ok, agent} = Agents.create_agent(%{name: name, harness: "claude", provider: "anthropic"})
    send(view.pid, {:agent_created, agent})
    _ = render(view)
    agent
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  defp usage_event(input, output, cache_read) do
    usage = %{"input_tokens" => input, "output_tokens" => output}
    usage = if cache_read, do: Map.put(usage, "cache_read_input_tokens", cache_read), else: usage

    frame = %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => "hi"}], "usage" => usage}
    }

    {:ok, events} = Claude.normalize(frame, @ctx)
    Enum.find(events, &match?(%Event.Usage{}, &1))
  end

  test "the agent card cost badge reflects the cached-prompt tokens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent = create_agent(view, uniq_name())

    # Baseline (no cache) and cached estimates, both derived through the real harness path.
    base = usage_event(10_000, 1_000, nil)
    cached = usage_event(10_000, 1_000, 1_000_000)

    assert cached.estimated_cost_usd > base.estimated_cost_usd,
           "the cache-aware estimate must exceed the input+output-only figure"

    Dashboard.broadcast_event(agent.id, cached)

    expected = "~$#{:erlang.float_to_binary(cached.estimated_cost_usd, decimals: 2)}"

    assert wait_until(fn -> render(element(view, "#agent-#{agent.id}")) =~ expected end),
           "the cost badge must render the cache-aware estimate"
  end
end
