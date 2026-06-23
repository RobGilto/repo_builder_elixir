defmodule RepoBuilder.Orchestrator.ContextWindowResolutionTest do
  @moduledoc """
  Layered resolution for `RepoBuilder.Orchestrator.ContextWindow.size/2`:
  operator config override → derived/live (pi) or built-in catalog → `:default`.

  These tests mutate `config :repo_builder, :context_windows` to isolate each layer;
  the live pi source is disabled in the test env (`:pi_models_discovery`), so the pi
  path resolves through the catalog/default deterministically.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Orchestrator.ContextWindow

  setup do
    original = Application.get_env(:repo_builder, :context_windows)
    on_exit(fn -> Application.put_env(:repo_builder, :context_windows, original) end)
    :ok
  end

  defp put_config(map), do: Application.put_env(:repo_builder, :context_windows, map)

  describe "size/2 layered precedence" do
    test "operator config override wins over the built-in catalog" do
      # Catalog says claude-sonnet-4-6 is 1M; an override must win.
      put_config(%{:default => 200_000, {"claude", "claude-sonnet-4-6"} => 500_000})
      assert ContextWindow.size("claude", "claude-sonnet-4-6") == 500_000
    end

    test "built-in catalog resolves a known Claude model with no config override" do
      put_config(%{:default => 200_000})
      assert ContextWindow.size("claude", "claude-sonnet-4-6") == 1_000_000
      assert ContextWindow.size("claude", "claude-opus-4-8") == 1_000_000
      assert ContextWindow.size("claude", "claude-haiku-4-5-20251001") == 200_000
    end

    test "unknown {harness, model} falls back to the configured :default" do
      put_config(%{:default => 123_456})
      assert ContextWindow.size("claude", "totally-unknown-model") == 123_456
      assert ContextWindow.size("nonexistent-harness", "whatever") == 123_456
    end

    test "missing :default falls back to the hardcoded 200_000" do
      put_config(%{})
      assert ContextWindow.size("claude", "totally-unknown-model") == 200_000
    end

    test "nil model resolves (no crash) to the default for an uncatalogued harness" do
      put_config(%{:default => 200_000})
      assert ContextWindow.size("pi", nil) == 200_000
      assert ContextWindow.size("claude", nil) == 200_000
    end

    test "pi harness with discovery disabled falls through to the default" do
      # :pi_models_discovery is false in test config, so Models.context_window/1 -> nil.
      put_config(%{:default => 200_000})
      assert ContextWindow.size("pi", "MiniMax-M3") == 200_000
    end
  end

  describe "usage_fraction/3 (unchanged semantics)" do
    test "is unclamped — reports over-occupancy verbatim" do
      put_config(%{:default => 200_000})
      # 300k against a 200k window => 1.5
      assert ContextWindow.usage_fraction(300_000, "claude", "totally-unknown-model") == 1.5
    end

    test "computes against the resolved (catalog) window" do
      put_config(%{:default => 200_000})
      # 500k against sonnet's 1M catalog window => 0.5
      assert ContextWindow.usage_fraction(500_000, "claude", "claude-sonnet-4-6") == 0.5
    end
  end
end
