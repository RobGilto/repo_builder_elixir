defmodule RepoBuilder.WorkflowEngine.Step do
  @moduledoc """
  A typed ADW step (BUILD_PROMPT.md §7). Step order/branching is FIXED and
  deterministic; the intelligent work INSIDE `:running` is delegated to a harness.

  Lifecycle: `pending → running → (succeeded | failed | cancelled)`. The
  `on_success`/`on_failure` edges are deterministic: a next step name, or `:done`
  (success terminal) / `:abort` (failure terminal).
  """
  use TypedStruct

  @type status :: :pending | :running | :succeeded | :failed | :cancelled
  @type edge :: String.t() | :done | :abort

  typedstruct enforce: true do
    field :name, String.t()
    field :harness, String.t()
    field :provider, String.t(), enforce: false
    field :model, String.t(), enforce: false
    field :prompt_template, String.t(), default: ""
    field :on_success, edge(), default: :done
    field :on_failure, edge(), default: :abort
    field :inputs, [String.t()], default: []
    field :outputs, [String.t()], default: []
    field :status, status(), default: :pending
  end

  @doc "Build a Step from a string-keyed JSONB definition map."
  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      harness: Map.fetch!(map, "harness"),
      provider: Map.get(map, "provider"),
      model: Map.get(map, "model"),
      prompt_template: Map.get(map, "prompt_template", ""),
      on_success: parse_edge(Map.get(map, "on_success"), :done),
      on_failure: parse_edge(Map.get(map, "on_failure"), :abort),
      inputs: Map.get(map, "inputs", []),
      outputs: Map.get(map, "outputs", [])
    }
  end

  defp parse_edge(nil, default), do: default
  defp parse_edge("done", _default), do: :done
  defp parse_edge("abort", _default), do: :abort
  defp parse_edge(name, _default) when is_binary(name), do: name
end
