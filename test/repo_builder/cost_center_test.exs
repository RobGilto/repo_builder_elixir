defmodule RepoBuilder.CostCenterTest do
  @moduledoc """
  Unit tests for the Cost Center context (issue-cost-center): seed idempotency +
  manual-preserving upsert, catalog CRUD, `price_table_for/1` shape, and the dimensional
  `rollup/1` (grouping, ordering, actual-vs-estimated cost, nil-vs-0 preservation,
  `:include_hidden?`).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, CostCenter}
  alias RepoBuilder.CostCenter.ModelPrice
  alias RepoBuilder.Harness.Pricing
  alias RepoBuilder.Logs.{AgentLog, Usage}
  alias RepoBuilder.Repo

  defp uniq, do: System.unique_integer([:positive])

  defp agent_fixture do
    {:ok, agent} =
      Agents.create_agent(%{name: "agent-#{uniq()}", harness: "claude", provider: :anthropic})

    agent
  end

  # Insert a cost-bearing agent_logs row directly (struct insert so we control
  # inserted_at for deterministic ordering and the embedded Usage value object).
  defp log_fixture(agent, opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    usage =
      case Keyword.get(opts, :cost, :none) do
        :none ->
          %Usage{input_tokens: opts[:input] || 0, output_tokens: opts[:output] || 0}

        cost ->
          %Usage{
            input_tokens: opts[:input] || 0,
            output_tokens: opts[:output] || 0,
            cost_usd: cost
          }
      end

    Repo.insert!(%AgentLog{
      agent_id: agent.id,
      session_id: "s-#{uniq()}",
      event_type: :usage,
      harness: Keyword.fetch!(opts, :harness),
      provider: opts[:provider],
      model: opts[:model],
      hidden: Keyword.get(opts, :hidden, false),
      usage: usage,
      inserted_at: at,
      updated_at: at
    })
  end

  describe "seed_prices/0" do
    test "is idempotent and never duplicates" do
      assert {:ok, n} = CostCenter.seed_prices()
      assert n > 0
      count1 = Repo.aggregate(ModelPrice, :count)

      assert {:ok, ^n} = CostCenter.seed_prices()
      assert Repo.aggregate(ModelPrice, :count) == count1
    end

    test "preserves an operator :manual edit across re-seed" do
      {:ok, _} = CostCenter.seed_prices()

      {:ok, edited} =
        CostCenter.upsert_price(%{
          harness: "pi",
          provider: "zai",
          model: "glm-4.6",
          input_price_per_mtok: "9.99",
          output_price_per_mtok: "9.99"
        })

      assert edited.source == :manual

      {:ok, _} = CostCenter.seed_prices()
      reloaded = CostCenter.get_price("pi", "zai", "glm-4.6")
      assert reloaded.source == :manual
      assert Decimal.equal?(reloaded.input_price_per_mtok, Decimal.new("9.99"))
    end
  end

  describe "catalog CRUD" do
    test "upsert_price/1 inserts then updates in place, marking source :manual" do
      assert {:ok, p1} =
               CostCenter.upsert_price(%{
                 harness: "pi",
                 provider: "zai",
                 model: "glm-x",
                 input_price_per_mtok: "1.0",
                 output_price_per_mtok: "2.0"
               })

      assert p1.source == :manual

      assert {:ok, p2} =
               CostCenter.upsert_price(%{
                 harness: "pi",
                 provider: "zai",
                 model: "glm-x",
                 input_price_per_mtok: "1.5",
                 output_price_per_mtok: "3.0"
               })

      assert p2.id == p1.id
      assert Repo.aggregate(ModelPrice, :count, :id) == 1
      assert Decimal.equal?(p2.output_price_per_mtok, Decimal.new("3.0"))
    end

    test "upsert_price/1 normalizes a nil provider to \"\"" do
      assert {:ok, p} =
               CostCenter.upsert_price(%{harness: "pi", model: "m1", input_price_per_mtok: "1.0"})

      assert p.provider == ""
      assert CostCenter.get_price("pi", nil, "m1").id == p.id
    end

    test "upsert_price/1 rejects an unregistered harness and a negative price" do
      assert {:error, cs} = CostCenter.upsert_price(%{harness: "nope", model: "m"})
      assert "is invalid" in errors_on(cs).harness

      assert {:error, cs2} =
               CostCenter.upsert_price(%{harness: "pi", model: "m", input_price_per_mtok: "-1"})

      assert "must be greater than or equal to 0" in errors_on(cs2).input_price_per_mtok
    end

    test "delete_price/1 happy + missing paths" do
      {:ok, p} = CostCenter.upsert_price(%{harness: "pi", model: "gone"})
      assert {:ok, _} = CostCenter.delete_price(p.id)
      assert CostCenter.get_price("pi", "", "gone") == nil
      assert {:error, :not_found} = CostCenter.delete_price(Ecto.UUID.generate())
    end

    test "list_prices/0 is ordered by (harness, provider, model)" do
      {:ok, _} = CostCenter.upsert_price(%{harness: "pi", model: "b"})
      {:ok, _} = CostCenter.upsert_price(%{harness: "claude", model: "a"})
      models = CostCenter.list_prices() |> Enum.map(& &1.harness)
      assert models == Enum.sort(models)
    end
  end

  describe "get_price/1 + update_price/2" do
    test "get_price/1 returns the row by id and nil for an unknown UUID" do
      {:ok, p} = CostCenter.upsert_price(%{harness: "pi", model: "by-id"})
      assert CostCenter.get_price(p.id).id == p.id
      assert CostCenter.get_price(Ecto.UUID.generate()) == nil
    end

    test "update_price/2 updates the rate in place (same id, count unchanged), forcing :manual" do
      {:ok, p} =
        CostCenter.upsert_price(%{
          harness: "pi",
          model: "edit-me",
          output_price_per_mtok: "1.0"
        })

      assert {:ok, updated} = CostCenter.update_price(p, %{"output_price_per_mtok" => "2.0"})
      assert updated.id == p.id
      assert updated.source == :manual
      assert Decimal.equal?(updated.output_price_per_mtok, Decimal.new("2.0"))
      assert Repo.aggregate(ModelPrice, :count, :id) == 1
    end

    test "update_price/2 preserves the identity key when the caller omits key fields" do
      {:ok, p} =
        CostCenter.upsert_price(%{harness: "pi", provider: "zai", model: "keep-key"})

      # The LiveView contract: only rate params reach update_price/2 (keys are locked).
      assert {:ok, updated} = CostCenter.update_price(p, %{"output_price_per_mtok" => "3.0"})
      assert updated.harness == "pi"
      assert updated.provider == "zai"
      assert updated.model == "keep-key"
      assert CostCenter.get_price("pi", "zai", "keep-key").id == p.id
    end

    test "update_price/2 returns {:error, changeset} on a negative price" do
      {:ok, p} = CostCenter.upsert_price(%{harness: "pi", model: "neg"})

      assert {:error, %Ecto.Changeset{} = cs} =
               CostCenter.update_price(p, %{"input_price_per_mtok" => "-1"})

      assert "must be greater than or equal to 0" in errors_on(cs).input_price_per_mtok
    end
  end

  describe "price_table_for/1" do
    test "returns %{model => combined_rate}, preferring the output rate" do
      {:ok, _} =
        CostCenter.upsert_price(%{
          harness: "pi",
          model: "glm-4.6",
          input_price_per_mtok: "0.6",
          output_price_per_mtok: "2.2"
        })

      assert CostCenter.price_table_for("pi") == %{"glm-4.6" => 2.2}
    end

    test "falls back to the input rate when output is absent, omits rateless rows" do
      {:ok, _} =
        CostCenter.upsert_price(%{
          harness: "pi",
          model: "only-input",
          input_price_per_mtok: "0.5"
        })

      {:ok, _} = CostCenter.upsert_price(%{harness: "pi", model: "no-rate"})

      table = CostCenter.price_table_for("pi")
      assert table["only-input"] == 0.5
      refute Map.has_key?(table, "no-rate")
    end
  end

  describe "pricing integration" do
    test "a catalog entry derives a cost where the config table alone left it nil" do
      config_table = Application.fetch_env!(:repo_builder, :harnesses)["pi"][:price_table]
      # A model the hard-coded config price_table does NOT know.
      assert Pricing.derive("brand-new-model", 1_000_000, 0, config_table) == nil

      {:ok, _} =
        CostCenter.upsert_price(%{
          harness: "pi",
          model: "brand-new-model",
          output_price_per_mtok: "3.0"
        })

      merged = Map.merge(config_table, CostCenter.price_table_for("pi"))
      assert Pricing.derive("brand-new-model", 1_000_000, 0, merged) == 3.0
    end
  end

  describe "rollup/1" do
    test "groups by (harness, provider, model), summing only priced cost" do
      agent = agent_fixture()

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        model: "claude-opus-4-8",
        input: 1000,
        output: 500,
        cost: Decimal.new("0.25")
      )

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        model: "claude-opus-4-8",
        input: 200,
        output: 100,
        cost: Decimal.new("0.10")
      )

      assert [row] = CostCenter.rollup([])
      assert row.harness == "claude"
      assert row.model == "claude-opus-4-8"
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new("0.35"))
      assert row.input_tokens == 1200
      assert row.output_tokens == 600
      assert row.event_count == 2
      refute row.estimated?
      assert row.estimated_cost_usd == nil
    end

    test "estimates cost for an unpriced dimension that the catalog prices" do
      {:ok, _} =
        CostCenter.upsert_price(%{
          harness: "pi",
          provider: "zai",
          model: "glm-4.6",
          output_price_per_mtok: "2.0"
        })

      agent = agent_fixture()

      log_fixture(agent,
        harness: "pi",
        provider: "zai",
        model: "glm-4.6",
        input: 500_000,
        output: 500_000,
        cost: nil
      )

      assert [row] = CostCenter.rollup([])
      assert row.estimated?
      # (500k + 500k) / 1e6 * 2.0 = 2.0
      assert Decimal.equal?(Decimal.round(row.estimated_cost_usd, 2), Decimal.new("2.00"))
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new(0))
    end

    test "leaves estimated_cost_usd nil when no catalog price exists (nil-vs-0 preserved)" do
      agent = agent_fixture()

      log_fixture(agent,
        harness: "pi",
        provider: "zai",
        model: "no-price-model",
        input: 1000,
        output: 1000,
        cost: nil
      )

      assert [row] = CostCenter.rollup([])
      refute row.estimated?
      assert row.estimated_cost_usd == nil
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new(0))
    end

    test "a priced-at-zero dimension stays actual (no estimate), distinct from unpriced" do
      {:ok, _} =
        CostCenter.upsert_price(%{harness: "pi", model: "zero", output_price_per_mtok: "5.0"})

      agent = agent_fixture()

      log_fixture(agent,
        harness: "pi",
        provider: "",
        model: "zero",
        input: 1000,
        output: 1000,
        cost: Decimal.new("0")
      )

      assert [row] = CostCenter.rollup([])
      refute row.estimated?
      assert row.estimated_cost_usd == nil
      assert Decimal.equal?(row.actual_cost_usd, Decimal.new(0))
    end

    test "orders by last_used_at DESC and honors :include_hidden?" do
      agent = agent_fixture()
      now = DateTime.utc_now()

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        model: "old",
        cost: Decimal.new("0.1"),
        at: DateTime.add(now, -60, :second)
      )

      log_fixture(agent,
        harness: "claude",
        provider: "anthropic",
        model: "new",
        cost: Decimal.new("0.1"),
        at: now
      )

      log_fixture(agent,
        harness: "pi",
        provider: "zai",
        model: "hidden-one",
        cost: Decimal.new("0.1"),
        hidden: true,
        at: now
      )

      visible = CostCenter.rollup([])
      assert Enum.map(visible, & &1.model) == ["new", "old"]

      with_hidden = CostCenter.rollup(include_hidden?: true)
      assert "hidden-one" in Enum.map(with_hidden, & &1.model)
    end
  end
end
