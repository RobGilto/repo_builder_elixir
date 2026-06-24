defmodule RepoBuilder.SamplePlugins.NoopHarness.Adapter do
  @moduledoc """
  A no-op harness adapter contributed by the `noop-harness` sample plugin. Proves the
  §10 promise that a new harness can arrive entirely via a dropped-in plugin: it
  implements only the mandatory `RepoBuilder.Harness` callbacks and every wire frame
  normalizes to `:skip` (mirroring `RepoBuilder.Harness.Cursor`).

  Loaded at runtime by `RepoBuilder.Plugins.Loader` via `Code.require_file/1` — it is
  NOT part of `mix compile` (it lives under `plugin_library/`, outside `lib/`).
  """
  @behaviour RepoBuilder.Harness

  @impl true
  def command(opts) do
    env = opts |> Map.get(:secrets, %{}) |> Map.to_list()
    {"true", [], env, %{harness: :noop}}
  end

  @impl true
  def normalize(_raw, _ctx), do: :skip
end
