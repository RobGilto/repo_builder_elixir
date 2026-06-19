defmodule RepoBuilder.Harness.PricingTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Event, Pi, Pricing}
  alias RepoBuilder.Harness.Pricing.Rate

  describe "Pricing.derive/3" do
    test "computes (tokens / 1e6) * price_per_mtok for a flat number rate" do
      # (1_000_000 + 0) / 1e6 * 0.6 = 0.6
      assert Pricing.derive("glm-4.6", %{input: 1_000_000, output: 0}, %{"glm-4.6" => 0.6}) == 0.6

      assert Pricing.derive("glm-4.6", %{input: 500_000, output: 500_000}, %{"glm-4.6" => 0.6}) ==
               0.6
    end

    test "prices input and output at their own Rate columns" do
      table = %{"m" => %Rate{input: 3.0, output: 15.0}}
      # 1_000_000 in * 3 + 1_000_000 out * 15 = 18.0 (/1e6 over Mtok)
      assert Pricing.derive("m", %{input: 1_000_000, output: 1_000_000}, table) == 18.0
    end

    test "cache_read billed at 0.1x and cache_creation at 1.25x the input rate" do
      table = %{"m" => %Rate{input: 10.0, output: 50.0}}

      # cache_read: 1_000_000 * 10 * 0.1 = 1.0
      assert Pricing.derive("m", %{input: 0, output: 0, cache_read: 1_000_000}, table) == 1.0

      # cache_creation: 1_000_000 * 10 * 1.25 = 12.5
      assert Pricing.derive("m", %{input: 0, output: 0, cache_creation: 1_000_000}, table) == 12.5
    end

    test "a bare-number table applies cache multipliers against that number" do
      # input rate = output rate = 6.0; cache_read 1_000_000 * 6 * 0.1 = 0.6
      assert Pricing.derive("m", %{input: 0, output: 0, cache_read: 1_000_000}, %{"m" => 6.0}) ==
               0.6
    end

    test "a large cache_read makes the estimate exceed the input+output-only figure" do
      table = %{"m" => %Rate{input: 75.0, output: 75.0}}
      base = Pricing.derive("m", %{input: 10_000, output: 1_000}, table)

      with_cache =
        Pricing.derive("m", %{input: 10_000, output: 1_000, cache_read: 1_000_000}, table)

      assert with_cache > base
    end

    test "nil/absent cache tokens are safe" do
      table = %{"m" => %Rate{input: 1.0, output: 1.0}}

      assert Pricing.derive(
               "m",
               %{input: 10, output: 5, cache_read: nil, cache_creation: nil},
               table
             ) ==
               Pricing.derive("m", %{input: 10, output: 5}, table)
    end

    test "returns nil (never 0.0) for an unpriced or unknown model" do
      assert Pricing.derive("unknown", %{input: 100, output: 100}, %{"glm-4.6" => 0.6}) == nil
      assert Pricing.derive(nil, %{input: 100, output: 100}, %{"glm-4.6" => 0.6}) == nil
      assert Pricing.derive("glm-4.6", %{input: 100, output: 100}, %{}) == nil
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
