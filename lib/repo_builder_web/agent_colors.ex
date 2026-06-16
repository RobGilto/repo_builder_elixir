defmodule RepoBuilderWeb.AgentColors do
  @moduledoc """
  Deterministic, stable per-agent color (BUILD_PROMPT.md §9 console).

  Maps any agent id/name (an arbitrary binary) to a stable hue from a fixed
  palette via `:erlang.phash2`, so the same agent always renders with the same
  color across the rail border, the event-row accent, the swimlane squares, and
  the `--pulse-color` CSS var. Pure, total over arbitrary binaries, no `Repo`.
  """

  @typedoc "A resolved agent color: its hex string, an `r, g, b` triple string, and a stable class."
  @type t :: %{hex: String.t(), rgb: String.t(), class: String.t()}

  # ≈12 colors drawn from the reference accent set (cyan/teal/purple + status hues).
  @palette [
    "#06b6d4",
    "#14b8a6",
    "#a855f7",
    "#8b5cf6",
    "#3b82f6",
    "#10b981",
    "#f59e0b",
    "#ef4444",
    "#ec4899",
    "#22d3ee",
    "#84cc16",
    "#f97316"
  ]

  @doc "The full fixed palette (hex strings). Useful for tests and legends."
  @spec palette() :: [String.t()]
  def palette, do: @palette

  @doc "The stable hex color for an agent key (id or name). Total over arbitrary binaries."
  @spec hex(String.t()) :: String.t()
  def hex(key) when is_binary(key) do
    Enum.at(@palette, :erlang.phash2(key, length(@palette)))
  end

  @doc "The agent's color as an `\"r, g, b\"` triple string (for rgba() composition)."
  @spec rgb(String.t()) :: String.t()
  def rgb(key) when is_binary(key) do
    <<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex(key)
    "#{hex_to_int(r)}, #{hex_to_int(g)}, #{hex_to_int(b)}"
  end

  @doc "A stable, CSS-safe class fragment for an agent key (`agent-color-N`)."
  @spec class(String.t()) :: String.t()
  def class(key) when is_binary(key) do
    "agent-color-#{:erlang.phash2(key, length(@palette))}"
  end

  @doc "All three representations at once (rail/border/square consumers)."
  @spec assigns(String.t()) :: t()
  def assigns(key) when is_binary(key) do
    %{hex: hex(key), rgb: rgb(key), class: class(key)}
  end

  @spec hex_to_int(String.t()) :: non_neg_integer()
  defp hex_to_int(byte), do: String.to_integer(byte, 16)
end
