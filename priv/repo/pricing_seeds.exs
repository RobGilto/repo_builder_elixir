# Initial price catalog (issue-cost-center) — checked-in reference data so the
# `model_prices` table never starts from scratch. Consumed idempotently by
# `RepoBuilder.CostCenter.seed_prices/0` (invoked from `priv/repo/seeds.exs` and
# `mix ecto.setup`). Data-only: a list of `%{harness, provider, model, input/output
# price per Mtok}` maps. Rates are USD per million tokens.
#
# Derived from `config/config.exs` per-harness `price_table`s (pi's GLM models) plus a
# few well-known anchors (Claude) so the catalog is useful immediately. The operator
# edits these in the Cost Center settings tab; manual edits are preserved across re-seed.

[
  # pi (unpriced harness): GLM models from pi's config price_table, served via zai.
  %{harness: "pi", provider: "zai", model: "glm-4.6", input_price_per_mtok: "0.6", output_price_per_mtok: "2.2"},
  %{harness: "pi", provider: "zai", model: "glm-4.5-air", input_price_per_mtok: "0.2", output_price_per_mtok: "1.1"},

  # Claude anchors (Claude reports its own USD, but the catalog documents the rates).
  %{harness: "claude", provider: "anthropic", model: "claude-fable-5", input_price_per_mtok: "10.0", output_price_per_mtok: "50.0"},
  %{harness: "claude", provider: "anthropic", model: "claude-opus-4-8", input_price_per_mtok: "15.0", output_price_per_mtok: "75.0"},
  %{harness: "claude", provider: "anthropic", model: "claude-sonnet-4-6", input_price_per_mtok: "3.0", output_price_per_mtok: "15.0"},
  %{harness: "claude", provider: "anthropic", model: "claude-haiku-4-5", input_price_per_mtok: "0.8", output_price_per_mtok: "4.0"}
]
