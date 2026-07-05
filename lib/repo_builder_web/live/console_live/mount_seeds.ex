defmodule RepoBuilderWeb.ConsoleLive.MountSeeds do
  @moduledoc """
  Telemetry span wrapper for ConsoleLive's mount seed chain
  (specs/console-mount-seed-optimization.html Phase 1).

  Every seed step in the connected mount (and the deferred `:seed_history`
  hydration) runs through `span/3`, emitting
  `[:repo_builder, :console, :seed, :start | :stop]` with `%{seed: name}`
  metadata. The dev `RepoBuilder.Telemetry.LiveViewPerf` handler prints each
  stop as `[lv_perf] seed <name> N ms`; `RepoBuilderWeb.Telemetry` charts the
  per-seed summary in LiveDashboard. Spans are cheap no-ops when nothing is
  attached, so this wraps prod/test too.
  """

  alias Phoenix.LiveView.Socket

  @doc "Run one named seed step inside a `[:repo_builder, :console, :seed]` telemetry span."
  @spec span(Socket.t(), atom(), (Socket.t() -> Socket.t())) :: Socket.t()
  def span(socket, name, fun) do
    :telemetry.span([:repo_builder, :console, :seed], %{seed: name}, fn ->
      {fun.(socket), %{seed: name}}
    end)
  end
end
