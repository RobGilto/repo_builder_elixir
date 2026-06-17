defmodule RepoBuilder.Orchestrator.ContextWindow do
  @moduledoc """
  Harness-blind context-window sizing (issue: cost + compaction). Reads the
  operator-tunable `config :repo_builder, :context_windows` map — a `%{default =>
  integer, {harness, model} => integer}` lookup — so "how full is the context window"
  is meaningful across harnesses (the reference hardcoded 200k for Claude only).

  `usage_fraction/3` is deliberately UNCLAMPED: a value > 1.0 (over 100%) is the exact
  condition the brain/operator needs to see, so it is reported verbatim.
  """

  @default_size 200_000

  @doc """
  The context-window size (in tokens) for `harness`+`model`. A per-`{harness, model}`
  override wins; otherwise the configured `:default` (falling back to 200_000).
  """
  @spec size(String.t(), String.t() | nil) :: pos_integer()
  def size(harness, model) when is_binary(harness) do
    config = windows_config()

    case Map.get(config, {harness, model}) do
      override when is_integer(override) and override > 0 -> override
      _absent -> default_size(config)
    end
  end

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
