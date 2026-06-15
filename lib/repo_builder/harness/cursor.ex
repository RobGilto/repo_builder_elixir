defmodule RepoBuilder.Harness.Cursor do
  @moduledoc """
  No-op `cursor-agent` adapter (BUILD_PROMPT.md §10) — the EXTENSIBILITY PROOF.

  This module plus one `:harnesses` config entry is ALL it takes to add a third
  harness: ZERO edits to the canonical `Event` types, the `Agent` schema, or the
  runtime. It implements only the mandatory `RepoBuilder.Harness` behaviour
  (`command/1` + `normalize/2`); the generic erlexec runtime (§6) drives it. The
  open `harness :: atom()` identity (§3 rule 5) is what makes this possible.

  The normalizer is intentionally a stub (every frame `:skip`) — wiring up real
  Cursor wire frames is future work; the point here is that the platform accepts a
  new harness with no core change.
  """
  @behaviour RepoBuilder.Harness

  @impl true
  def command(opts) do
    {"cursor-agent", ["--json", opts.prompt], env(opts), %{harness: :cursor}}
  end

  @impl true
  def normalize(_raw, _ctx), do: :skip

  @spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
  defp env(opts) do
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
