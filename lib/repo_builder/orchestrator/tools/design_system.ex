defmodule RepoBuilder.Orchestrator.Tools.DesignSystem do
  @moduledoc """
  Design-system tool (design-system-plugins): resolve the bound project's active design
  system and return its tokens + component inventory + rules + paradigm as JSON — the
  platform-native analog of a component-library MCP server (e.g. Petal's). A worker calls
  it to pull the exact vocabulary + examples on demand instead of hand-rolling markup,
  complementing the compact `DesignContract` block already folded into its charter.

  Two optional narrowing args: `section` (`tokens` | `components` | `rules` | `references`)
  returns just that slice, and `component` filters the inventory to one component by name.
  """

  import RepoBuilder.Orchestrator.Tools.Shared, only: [orchestrator_project_id: 1]

  alias RepoBuilder.Orchestrator.DesignResolver
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Plugins.DesignSystem
  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Project

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  @sections ~w(tokens components rules references)

  @doc """
  Resolve the design system for the orchestrator's bound project. `:no_project` is an
  honest error the brain can act on (register a project). Optionally narrow to a `section`
  or a single `component`.
  """
  @spec resolve_design_system(Ecto.UUID.t(), map()) :: result()
  def resolve_design_system(orchestrator_id, args) do
    with {:ok, resolved} <- resolve_project_design(orchestrator_id) do
      {:ok, design_map(resolved, args)}
    end
  end

  # The resolved design system for the orchestrator's bound project.
  @spec resolve_project_design(Ecto.UUID.t()) :: {:ok, DesignResolver.t()} | {:error, reason()}
  defp resolve_project_design(orchestrator_id) do
    with project_id when is_binary(project_id) <-
           orchestrator_project_id(orchestrator_id) || :no_project,
         {:ok, %Project{} = project} <- fetch_project(project_id) do
      case DesignResolver.resolve(project) do
        {:ok, resolved} -> {:ok, resolved}
        {:error, :none} -> {:error, :no_design}
      end
    else
      :no_project -> {:error, :no_project}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :project_not_found}
  defp fetch_project(project_id) do
    case Projects.fetch_project(project_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      {:error, _reason} -> {:error, :project_not_found}
    end
  end

  # Build the JSON-friendly design map, applying the optional `component` + `section` filters.
  # Inference-only (the string-keyed map narrows below a hand-written `map()`).
  defp design_map(%DesignResolver{descriptor: %DesignSystem{} = ds} = resolved, args) do
    meta = %{
      "name" => resolved.name,
      "source" => to_string(resolved.source),
      "surface" => to_string(ds.surface),
      "stack" => ds.stack,
      "framework" => ds.framework,
      "paradigm" => to_string(ds.paradigm)
    }

    sections = %{
      "tokens" => ds.tokens,
      "components" =>
        ds.components |> filter_component(args["component"]) |> Enum.map(&component_map/1),
      "rules" => ds.rules,
      "references" => ds.references
    }

    case section(args["section"]) do
      nil -> Map.merge(meta, sections)
      key -> Map.put(meta, key, Map.fetch!(sections, key))
    end
  end

  @spec filter_component([DesignSystem.Component.t()], term()) :: [DesignSystem.Component.t()]
  defp filter_component(components, query) when is_binary(query) and query != "" do
    needle = String.downcase(query)
    Enum.filter(components, &String.contains?(String.downcase(&1.name), needle))
  end

  defp filter_component(components, _query), do: components

  @spec component_map(DesignSystem.Component.t()) :: %{optional(String.t()) => String.t()}
  defp component_map(%DesignSystem.Component{} = component) do
    %{
      "name" => component.name,
      "tag" => component.tag,
      "package" => component.package,
      "when_to_use" => component.when_to_use,
      "example" => component.example
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec section(term()) :: String.t() | nil
  defp section(value) when value in @sections, do: value
  defp section(_value), do: nil
end
