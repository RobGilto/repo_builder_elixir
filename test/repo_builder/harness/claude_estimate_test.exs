defmodule RepoBuilder.Harness.ClaudeEstimateTest do
  @moduledoc """
  Proves claude derives a token-based live `estimated_cost_usd` on every usage event
  (intermediate + terminal) from the `ctx` price table, while keeping the authoritative
  `cost_usd` exactly as today: nil on intermediates, the real total on the terminal frame.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Event}

  @model "claude-opus-4-5"
  # Price the model at $30/Mtok so the estimate is a clean, positive number.
  @ctx %{harness: :claude, model: @model, price_table: %{@model => 30.0}}

  defp assistant_frame(input, output) do
    %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "usage" => %{"input_tokens" => input, "output_tokens" => output}
      }
    }
  end

  test "intermediate assistant usage carries an estimate but no authoritative cost" do
    assert {:ok, events} = Claude.normalize(assistant_frame(1_000_000, 0), @ctx)
    usage = Enum.find(events, &match?(%Event.Usage{}, &1))

    assert %Event.Usage{cost_usd: nil} = usage
    assert usage.estimated_cost_usd == 30.0
  end

  test "a large cache_read raises the estimate above the input+output-only figure" do
    base_frame = assistant_frame(10_000, 1_000)

    cached_frame =
      put_in(base_frame["message"]["usage"]["cache_read_input_tokens"], 1_000_000)

    assert {:ok, base_events} = Claude.normalize(base_frame, @ctx)
    assert {:ok, cached_events} = Claude.normalize(cached_frame, @ctx)

    base = Enum.find(base_events, &match?(%Event.Usage{}, &1))
    cached = Enum.find(cached_events, &match?(%Event.Usage{}, &1))

    # cache_read is now priced (0.1x input rate), so it must lift the estimate.
    assert cached.estimated_cost_usd > base.estimated_cost_usd
    assert cached.cache_read == 1_000_000
  end

  test "an unpriced model yields a nil estimate (never defaulted to 0)" do
    ctx = %{harness: :claude, model: "unknown-model", price_table: %{}}

    assert {:ok, events} = Claude.normalize(assistant_frame(1_000, 1_000), ctx)
    usage = Enum.find(events, &match?(%Event.Usage{}, &1))

    assert %Event.Usage{cost_usd: nil, estimated_cost_usd: nil} = usage
  end

  test "terminal result carries the authoritative cost on Done only, estimate on Usage" do
    frame = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "total_cost_usd" => 0.42,
      "usage" => %{"input_tokens" => 500_000, "output_tokens" => 500_000}
    }

    assert {:ok, events} = Claude.normalize(frame, @ctx)
    usage = Enum.find(events, &match?(%Event.Usage{}, &1))
    done = Enum.find(events, &match?(%Event.Done{}, &1))

    # Single-carrier invariant: cost on Done only (see issue-claude-cost).
    assert usage.cost_usd == nil
    assert usage.estimated_cost_usd == 30.0
    assert done.cost_usd == 0.42
  end
end
