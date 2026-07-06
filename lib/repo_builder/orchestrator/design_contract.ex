defmodule RepoBuilder.Orchestrator.DesignContract do
  @moduledoc """
  Render a project's resolved design system into the **design contract** — a compact
  markdown block folded onto the front of every UI worker's charter (after the stack
  contract) and surfaced in the orchestrator prompt, so a worker builds from a known
  component vocabulary + tokens + paradigm instead of regressing to generic markup.

  Mirrors `StackLayers.Contract.render/1`: typed data in, deterministic string out, and
  fail-silent. Returns `""` when there is no project, when the project can't be resolved,
  or when only the framework-agnostic `generic` descriptor resolves (a non-UI project) —
  so worker/orchestrator prompts are byte-identical to today's in those cases.

  Deliberately COMPACT: it carries the surface/framework, paradigm, tokens, component
  *tags*, and rules — not the full inventory with examples. A worker pulls the complete
  inventory on demand via the `resolve_design_system` MCP tool.
  """
  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Plugins.DesignSystem
  alias RepoBuilder.Projects

  @doc """
  Render the design-contract markdown for a project id (or `nil`). Empty when no project
  resolves or only the `generic` base applies. Never raises.
  """
  @spec render(Ecto.UUID.t() | nil) :: String.t()
  def render(project_id) do
    with id when is_binary(id) <- project_id,
         %Projects.Project{} = project <- Projects.get_project(id),
         {:ok, resolved} <- DesignResolver.resolve(project),
         false <- resolved.source == :generic do
      render_resolved(resolved)
    else
      _ -> ""
    end
  rescue
    _error -> ""
  end

  @spec render_resolved(DesignResolver.t()) :: String.t()
  defp render_resolved(%DesignResolver{descriptor: %DesignSystem{} = ds, source: source}) do
    """
    ## Design system — build the UI with THIS vocabulary (#{ds.surface}/#{ds.framework}, via #{source})
    #{paradigm_line(ds.paradigm)}#{tokens_block(ds.tokens)}
    Components — reach for these before hand-rolling markup:
    #{components_block(ds.components)}

    Rules:
    #{rules_block(ds.rules)}

    Resolve the full component inventory + examples any time via the `resolve_design_system` tool.
    """
    |> String.trim_trailing()
  end

  @spec paradigm_line(DesignSystem.paradigm()) :: String.t()
  defp paradigm_line(:none), do: ""

  defp paradigm_line(paradigm),
    do: "Paradigm: #{paradigm} — model the app's state/scaffolding accordingly (see rules).\n"

  @spec tokens_block(map()) :: String.t()
  defp tokens_block(tokens) when map_size(tokens) > 0 do
    "Tokens:\n" <>
      Enum.map_join(tokens, "\n", fn {key, value} -> "- #{key}: #{value}" end) <> "\n"
  end

  defp tokens_block(_tokens), do: ""

  @spec components_block([DesignSystem.Component.t()]) :: String.t()
  defp components_block([]), do: "- (none — a base/generic design system)"

  defp components_block(components) do
    Enum.map_join(components, "\n", fn %DesignSystem.Component{} = component ->
      case component.when_to_use do
        use when is_binary(use) and use != "" -> "- `#{component_label(component)}` — #{use}"
        _ -> "- `#{component_label(component)}`"
      end
    end)
  end

  @spec component_label(DesignSystem.Component.t()) :: String.t()
  defp component_label(%DesignSystem.Component{tag: tag}) when is_binary(tag) and tag != "",
    do: tag

  defp component_label(%DesignSystem.Component{package: pkg}) when is_binary(pkg) and pkg != "",
    do: pkg

  defp component_label(%DesignSystem.Component{name: name}), do: name

  @spec rules_block([String.t()]) :: String.t()
  defp rules_block([]), do: "- Follow the ui-ux-foundations rubric."
  defp rules_block(rules), do: Enum.map_join(rules, "\n", &("- " <> &1))
end
