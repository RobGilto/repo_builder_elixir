defmodule RepoBuilder.Harness.ModelResolverTest do
  @moduledoc """
  Unit tests for the harness-blind model-resolution seam (issue
  resolve-spawned-worker-models). Claude ids collapse to their family alias; catalog
  harnesses resolve to the latest-first sibling sharing a family stem. Pure + fail-soft:
  unknown family / absent catalog / unknown harness pass through unchanged.

  `:pi_models_discovery` is already disabled in the test env, so the catalog branch reads
  only the static `Registry.orchestrator_models/2` list and never shells out.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Harness.ModelResolver

  describe "claude — concrete id collapses to family alias" do
    test "sonnet/opus/haiku/fable concrete ids resolve to their alias" do
      assert ModelResolver.latest("claude", "anthropic", "claude-sonnet-4-5") == "sonnet"
      assert ModelResolver.latest("claude", "anthropic", "claude-opus-4-5") == "opus"
      assert ModelResolver.latest("claude", "anthropic", "claude-haiku-4-5") == "haiku"
      assert ModelResolver.latest("claude", "anthropic", "claude-fable-5") == "fable"
    end

    test "an already-family alias passes through unchanged" do
      assert ModelResolver.latest("claude", "anthropic", "opus") == "opus"
      assert ModelResolver.latest("claude", "anthropic", "sonnet") == "sonnet"
    end

    test "an unknown claude family passes through unchanged" do
      assert ModelResolver.latest("claude", "anthropic", "claude-frobnicate-9") ==
               "claude-frobnicate-9"

      assert ModelResolver.latest("claude", "anthropic", "claude-experimental-x") ==
               "claude-experimental-x"
    end

    test "provider is irrelevant for the claude branch" do
      assert ModelResolver.latest("claude", nil, "claude-opus-4-1") == "opus"
    end
  end

  describe "nil / blank model" do
    test "nil and empty string return as-is for any harness" do
      assert ModelResolver.latest("claude", "anthropic", nil) == nil
      assert ModelResolver.latest("pi", "openai", nil) == nil
      assert ModelResolver.latest("claude", "anthropic", "") == ""
      assert ModelResolver.latest("pi", "openai", "") == ""
    end
  end

  describe "pi / catalog — family-stem resolution against the static registry list" do
    test "a model with no sibling in the provider list passes through unchanged" do
      # Test registry: openai => ["gpt-5", "gpt-5-mini"]; neither shares a stem with the
      # other (gpt-5 stem `gpt`; gpt-5-mini stem `gpt-5-mini`).
      assert ModelResolver.latest("pi", "openai", "gpt-5") == "gpt-5"
    end

    test "gpt-5-mini never cross-upgrades to gpt-5 (conservative stem)" do
      assert ModelResolver.latest("pi", "openai", "gpt-5-mini") == "gpt-5-mini"
    end

    test "glm-4.5-air never cross-upgrades to glm-4.6 (variant stays its own family)" do
      # Test registry: zai => ["glm-4.6", "glm-4.5-air"].
      assert ModelResolver.latest("pi", "zai", "glm-4.5-air") == "glm-4.5-air"
      assert ModelResolver.latest("pi", "zai", "glm-4.6") == "glm-4.6"
    end

    test "an older sibling resolves to the latest-first registry entry of the same stem" do
      # Inject a provider list with two same-stem siblings (latest first) via the single
      # config seam; the older `glm-4.5` must resolve to `glm-4.7`.
      override_pi_models("zai", ["glm-4.7", "glm-4.5", "glm-4.5-air"])

      assert ModelResolver.latest("pi", "zai", "glm-4.5") == "glm-4.7"
      # The distinct `-air` variant still stays its own family.
      assert ModelResolver.latest("pi", "zai", "glm-4.5-air") == "glm-4.5-air"
    end
  end

  describe "fail-soft fallbacks" do
    test "an unknown harness with no registry entry passes through unchanged" do
      assert ModelResolver.latest("nope", "anthropic", "claude-opus-4-1") == "claude-opus-4-1"
    end

    test "a nil harness passes through unchanged (empty catalog)" do
      assert ModelResolver.latest(nil, nil, "some-model-2") == "some-model-2"
    end

    test "a provider with no registry list passes through unchanged" do
      assert ModelResolver.latest("pi", "no-such-provider", "weird-1") == "weird-1"
    end
  end

  # Temporarily override the pi harness's per-provider orchestrator model list through
  # the single `:harnesses` config seam; restored on exit.
  defp override_pi_models(provider, models) do
    harnesses = Application.fetch_env!(:repo_builder, :harnesses)
    pi = harnesses["pi"]
    orchestrator = Map.update!(pi.orchestrator, :models, &Map.put(&1, provider, models))
    updated_pi = Map.put(pi, :orchestrator, orchestrator)
    updated = Map.put(harnesses, "pi", updated_pi)

    Application.put_env(:repo_builder, :harnesses, updated)
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, harnesses) end)
  end
end
