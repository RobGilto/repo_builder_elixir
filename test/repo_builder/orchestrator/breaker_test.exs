defmodule RepoBuilder.Orchestrator.BreakerTest do
  @moduledoc """
  Self-healing Phase 4: the native ETS circuit breaker — trips after N consecutive failures,
  fails fast while open, half-opens after the cooldown, and closes on the next success. Uses
  the app-supervised singleton; `async: false` since it sets breaker config app-wide for the
  cooldown timing and shares the ETS table.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Orchestrator.Breaker

  setup do
    Breaker.reset()

    original = Application.get_env(:repo_builder, :orchestrator, [])

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.merge(original, breaker_max_failures: 3, breaker_cooldown_ms: 50)
    )

    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)
    :ok
  end

  test "a fresh key is closed and allowed" do
    assert Breaker.status("claude:opus") == :closed
    assert Breaker.ask("claude:opus") == :ok
  end

  test "trips to :open after breaker_max_failures and then fails fast" do
    key = "pi:glm-4.6"

    :ok = Breaker.fail(key)
    assert Breaker.ask(key) == :ok
    :ok = Breaker.fail(key)
    assert Breaker.ask(key) == :ok
    :ok = Breaker.fail(key)

    assert Breaker.status(key) == :open
    assert Breaker.ask(key) == {:error, :open}
  end

  test "half-opens after the cooldown and closes on the next success" do
    key = "claude:sonnet"
    Enum.each(1..3, fn _ -> Breaker.fail(key) end)
    assert Breaker.ask(key) == {:error, :open}

    Process.sleep(70)
    # Cooldown elapsed → a trial is admitted (half-open) even though still nominally :open.
    assert Breaker.ask(key) == :ok

    :ok = Breaker.succeed(key)
    assert Breaker.status(key) == :closed
    assert Breaker.ask(key) == :ok
  end

  test "a success resets the consecutive-failure count" do
    key = "claude:haiku"
    :ok = Breaker.fail(key)
    :ok = Breaker.fail(key)
    :ok = Breaker.succeed(key)

    # Two more failures should NOT trip (the count was reset by the success).
    :ok = Breaker.fail(key)
    :ok = Breaker.fail(key)
    assert Breaker.status(key) == :closed
    assert Breaker.ask(key) == :ok
  end

  test "key/2 builds a stable harness:model key" do
    assert Breaker.key("claude", "opus") == "claude:opus"
    assert Breaker.key("pi", nil) == "pi:?"
  end
end
