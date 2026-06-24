defmodule RepoBuilder.SamplePlugins.NoopHarness.Plugin do
  @moduledoc """
  The `on_load` entry point for the `noop-harness` code plugin. Registers the no-op
  adapter into the runtime `HarnessOverlay`, so `Harness.Registry.fetch("noop")`
  resolves it with zero edits to `Event`/`Agent`/runtime.
  """
  @behaviour RepoBuilder.Plugins.Code

  @impl true
  def on_load(_ctx) do
    RepoBuilder.Plugins.HarnessOverlay.put("noop", %{
      module: RepoBuilder.SamplePlugins.NoopHarness.Adapter,
      exe: "true",
      default_model: nil,
      price_table: %{}
    })

    :ok
  end

  @impl true
  def contributions, do: [:harness_adapter]
end
