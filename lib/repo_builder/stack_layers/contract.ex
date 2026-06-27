defmodule RepoBuilder.StackLayers.Contract do
  @moduledoc """
  Render a project's composed stack layers into the **stack contract** — a markdown
  "build ONLY within this stack" block injected into every worker's persisted system
  prompt (the load-bearing fix) and the orchestrator prompt. Mirrors
  `Projects.ContextPrimer.render/1`: typed data in, deterministic string out.

  Returns `""` when the project is `nil` or has no selected layers, so worker/orchestrator
  prompts are byte-identical to today's when a project hasn't composed a stack
  (fully back-compatible).
  """
  alias RepoBuilder.StackLayers
  alias RepoBuilder.StackLayers.StackLayer

  @doc """
  Render the stack-contract markdown for a project id (or `nil`). Reads the project's
  enabled selection via `StackLayers.layers_for_project/1`. Empty selection ⇒ `""`.
  """
  @spec render(Ecto.UUID.t() | nil) :: String.t()
  def render(project_id) do
    case StackLayers.layers_for_project(project_id) do
      [] -> ""
      layers -> render_layers(layers)
    end
  end

  @spec render_layers([StackLayer.t()]) :: String.t()
  defp render_layers(layers) do
    """
    ## Project stack — build ONLY within this stack
    #{Enum.map_join(layers, "\n", &layer_line/1)}

    Rules:
    - Use only the language/framework named for each layer; never introduce another for a listed layer.
    - If a task needs a layer not listed above, STOP and report back rather than guessing.
    """
    |> String.trim_trailing()
  end

  @spec layer_line(StackLayer.t()) :: String.t()
  defp layer_line(%StackLayer{} = layer) do
    base = "- #{type_label(layer.layer_type)}: #{layer.name} (#{layer.language})"

    case layer.reasoning do
      reasoning when is_binary(reasoning) and reasoning != "" -> base <> " — " <> reasoning
      _ -> base
    end
  end

  @spec type_label(StackLayer.layer_type() | nil) :: String.t()
  defp type_label(nil), do: "Layer"

  defp type_label(type) do
    type |> Atom.to_string() |> String.capitalize()
  end
end
