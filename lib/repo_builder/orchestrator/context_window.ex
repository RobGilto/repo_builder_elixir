defmodule RepoBuilder.Orchestrator.ContextWindow do
  @moduledoc """
  Harness-blind context-window sizing (issue: cost + compaction). Reads the
  operator-tunable `config :repo_builder, :context_windows` map — a `%{default =>
  integer, {harness, model} => integer}` lookup — so "how full is the context window"
  is meaningful across harnesses (the reference hardcoded 200k for Claude only).

  `usage_fraction/3` is deliberately UNCLAMPED: a value > 1.0 (over 100%) is the exact
  condition the brain/operator needs to see, so it is reported verbatim.

  Resolution is **layered**, in strict precedence:

    1. operator `config :repo_builder, :context_windows` `{harness, model}` override;
    2. a **derived/live** source — pi's advertised window (`pi --list-models`, via
       `RepoBuilder.Harness.Pi.Models`) for the `"pi"` harness, else the built-in
       `@known_windows` catalog of published model windows (Claude does not advertise its
       window in the stream, so it relies on the catalog);
    3. the configured `:default` (falling back to 200_000).

  Harness-blindness (§10): the only harness string matched here is the private `derive/2`
  `"pi"` special-case for the live source — the config-override and catalog layers work for
  any harness with zero code change.
  """

  alias RepoBuilder.Harness.Pi.Models

  @default_size 200_000

  # Built-in published context windows, keyed `{harness, model}`. These are sane defaults
  # for the models the platform ships with; an operator `:context_windows` config entry
  # overrides any value here. Claude does not advertise its window in the stream, so this
  # catalog is its source of truth.
  @known_windows %{
    {"claude", "claude-opus-4-8"} => 1_000_000,
    {"claude", "claude-sonnet-4-6"} => 1_000_000,
    {"claude", "claude-haiku-4-5-20251001"} => 200_000
  }

  @doc """
  The context-window size (in tokens) for `harness`+`model`. Resolves config override →
  derived/live (pi) or built-in catalog → configured `:default` (falling back to 200_000).
  Always returns a `pos_integer()`; never raises (a nil model resolves to the default).
  """
  @spec size(String.t(), String.t() | nil) :: pos_integer()
  def size(harness, model) when is_binary(harness) do
    config = windows_config()

    case Map.get(config, {harness, model}) do
      override when is_integer(override) and override > 0 ->
        override

      _absent ->
        case derive(harness, model) do
          derived when is_integer(derived) and derived > 0 -> derived
          _absent -> default_size(config)
        end
    end
  end

  # The derived/live layer: pi's advertised window for "pi", else the built-in catalog.
  # Returns nil when nothing is known so `size/2` falls through to the configured default.
  @spec derive(String.t(), String.t() | nil) :: pos_integer() | nil
  defp derive("pi", model), do: Models.context_window(model)
  defp derive(harness, model), do: Map.get(@known_windows, {harness, model})

  @doc """
  Context-window OCCUPANCY as `context_tokens / size`. NOT clamped — may exceed 1.0
  when a turn overruns the window. Zero/invalid size yields 0.0 (no div-by-zero).
  """
  @spec usage_fraction(non_neg_integer(), String.t(), String.t() | nil) :: float()
  def usage_fraction(context_tokens, harness, model)
      when is_integer(context_tokens) and context_tokens >= 0 do
    case size(harness, model) do
      window when is_integer(window) and window > 0 -> context_tokens / window
      _zero -> 0.0
    end
  end

  @spec windows_config() :: map()
  defp windows_config do
    case Application.get_env(:repo_builder, :context_windows) do
      config when is_map(config) -> config
      _absent -> %{}
    end
  end

  @spec default_size(map()) :: pos_integer()
  defp default_size(config) do
    case Map.get(config, :default) do
      size when is_integer(size) and size > 0 -> size
      _absent -> @default_size
    end
  end
end
