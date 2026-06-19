defmodule RepoBuilder.Harness.ClaudeCostSingleCarrierTest do
  @moduledoc """
  Encodes the single-carrier cost invariant for the claude harness: the authoritative
  `total_cost_usd` is stamped on exactly ONE terminal event (`Event.Done`), and the
  terminal `Event.Usage` carries `cost_usd: nil` (its token-derived `estimated_cost_usd`
  is preserved). Regression guard for issue-claude-cost (cost double-counted otherwise).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Logs}
  alias RepoBuilder.Harness.{Claude, Event}

  @model "claude-opus-4-5"
  @ctx %{harness: :claude, model: @model, price_table: %{@model => 30.0}}

  test "terminal result stamps cost on Done only; terminal Usage cost is nil" do
    frame = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "total_cost_usd" => 0.10,
      "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 0}
    }

    assert {:ok, events} = Claude.normalize(frame, @ctx)

    usage = Enum.find(events, &match?(%Event.Usage{}, &1))
    done = Enum.find(events, &match?(%Event.Done{}, &1))

    assert %Event.Usage{cost_usd: nil} = usage
    assert usage.estimated_cost_usd == 30.0
    assert %Event.Done{cost_usd: 0.10} = done
  end

  test "intermediate assistant usage also carries cost_usd: nil (unchanged)" do
    frame = %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 1_000}
      }
    }

    assert {:ok, events} = Claude.normalize(frame, @ctx)
    usage = Enum.find(events, &match?(%Event.Usage{}, &1))

    assert %Event.Usage{cost_usd: nil} = usage
  end

  test "persisting the fixed claude terminal pair rolls up the cost exactly once" do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "claude-rollup-#{System.unique_integer([:positive])}",
        harness: "claude",
        provider: "anthropic"
      })

    # The fixed claude terminal shape: token-only Usage (no cost) + Done carrying the total.
    {:ok, _} =
      Logs.persist_event(
        %Event.Usage{harness: :claude, input_tokens: 1_000, output_tokens: 1_000, cost_usd: nil},
        %{agent_id: agent.id, session_id: "s"}
      )

    {:ok, _} =
      Logs.persist_event(
        %Event.Done{harness: :claude, ok: true, reason: :success, cost_usd: 0.10},
        %{agent_id: agent.id, session_id: "s"}
      )

    assert Decimal.equal?(Logs.cost_rollup!(agent.id), Decimal.from_float(0.10))
  end
end
