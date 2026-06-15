defmodule RepoBuilder.Harness.RegistryTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Claude, Fake, Pi, Registry}

  test "all/0 returns the configured registry map" do
    all = Registry.all()
    assert is_map(all)
    assert Map.has_key?(all, "claude")
    assert Map.has_key?(all, "pi")
  end

  test "known/0 returns the harness keys (used by validate_inclusion at the write boundary)" do
    known = Registry.known()
    assert "claude" in known
    assert "pi" in known
  end

  test "fetch/1 resolves a string key to its adapter module" do
    assert Registry.fetch("claude") == {:ok, Claude}
    assert Registry.fetch("pi") == {:ok, Pi}
    assert Registry.fetch("fake") == {:ok, Fake}
  end

  test "fetch/1 coerces an atom key via to_string" do
    assert Registry.fetch(:claude) == {:ok, Claude}
    assert Registry.fetch(:pi) == {:ok, Pi}
  end

  test "fetch/1 returns {:error, :unknown_harness} for an unregistered key" do
    assert Registry.fetch("nope") == {:error, :unknown_harness}
    assert Registry.fetch(:nope) == {:error, :unknown_harness}
  end

  test "fetch_config/1 returns the full entry" do
    assert {:ok, %{module: Claude, exe: "claude"}} = Registry.fetch_config("claude")
    assert Registry.fetch_config("nope") == {:error, :unknown_harness}
  end
end
