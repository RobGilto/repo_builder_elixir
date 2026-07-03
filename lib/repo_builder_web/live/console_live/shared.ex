defmodule RepoBuilderWeb.ConsoleLive.Shared do
  @moduledoc """
  Cross-panel helpers for the decomposed `ConsoleLive` (docs/audit-2026-07.md F3,
  Phase 3): functions used by more than one console panel module live here as public,
  `@spec`'d functions. Panel-local helpers stay private in their panel module.
  """

  @doc "Operator-facing message when no Fast-tier agent is configured (smart import, explain)."
  @spec no_fast_agent_message() :: String.t()
  def no_fast_agent_message do
    "No Fast agent configured — pick a harness + model for the Fast tier under Agents…"
  end
end
