defmodule RepoBuilder.Harness.PricingTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Pi, Pricing}

  describe "Pricing.derive/4" do
    test "computes (tokens / 1e6) * price_per_mtok" do
      # (1_000_000 + 0) / 1e6 * 0.6 = 0.6
      assert Pricing.derive("glm-4.6", 1_000_000, 0, %{"glm-4.6" => 0.6}) == 0.6
      assert Pricing.derive("glm-4.6", 500_000, 500_000, %{"glm-4.6" => 0.6}) == 0.6
    end

    test "returns nil (never 0.0) for an unpriced or unknown model" do
      assert Pricing.derive("unknown", 100, 100, %{"glm-4.6" => 0.6}) == nil
      assert Pricing.derive(nil, 100, 100, %{"glm-4.6" => 0.6}) == nil
      assert Pricing.derive("glm-4.6", 100, 100, %{}) == nil
    end
  end

  describe "pi normalize derives cost via the threaded price table" do
    test "priced model yields a non-nil cost on the Usage event" do
      ctx = %{harness: :pi, model: "glm-4.6", price_table: %{"glm-4.6" => 0.6}}

      raw = %{
        "type" => "turn_end",
        "message" => %{"usage" => %{"input" => 1_000_000, "output" => 0}}
      }

      assert {:ok, [%Event.Usage{cost_usd: 0.6, input_tokens: 1_000_000}]} =
               Pi.normalize(raw, ctx)
    end

    test "unpriced model keeps cost nil (never defaulted to 0.0)" do
      ctx = %{harness: :pi, model: "unpriced", price_table: %{"glm-4.6" => 0.6}}
      raw = %{"type" => "turn_end", "message" => %{"usage" => %{"input" => 10, "output" => 5}}}

      assert {:ok, [%Event.Usage{cost_usd: nil}]} = Pi.normalize(raw, ctx)
    end

    test "a ctx without a price table (e.g. direct calls) keeps cost nil" do
      raw = %{"type" => "turn_end", "message" => %{"usage" => %{"input" => 10, "output" => 5}}}
      assert {:ok, [%Event.Usage{cost_usd: nil}]} = Pi.normalize(raw, %{harness: :pi})
    end
  end
end
