defmodule RepoBuilder.Orchestrator.Tools.AgentTemplates do
  @moduledoc """
  Subagent-template tools (self-healing Phase 5): list/fetch/save the reusable
  worker templates the orchestrator can spawn from. Extracted verbatim from the
  monolithic `Orchestrator.Tools` (audit F3) — behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [blank_to_nil: 1, fetch_string: 2, normalize_reason: 1]

  alias RepoBuilder.Orchestrator.Template
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilder.Orchestrator.Tools.Shared

  @type result :: Shared.result()

  @spec list_agent_templates() :: result()
  def list_agent_templates do
    templates =
      Enum.map(Templates.list(), fn template ->
        %{
          "name" => template.name,
          "description" => template.description,
          "version" => template.version
        }
      end)

    {:ok, %{"templates" => templates, "count" => length(templates)}}
  end

  @spec get_agent_template(map()) :: result()
  def get_agent_template(args) do
    with {:ok, name} <- fetch_string(args, "name") do
      case Templates.fetch(name) do
        {:ok, template} -> {:ok, template_view(template)}
        {:error, :not_found} -> {:error, template_not_found(name)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  @spec save_agent_template(map()) :: result()
  def save_agent_template(args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, description} <- fetch_string(args, "description"),
         {:ok, body} <- fetch_string(args, "system_prompt") do
      attrs = %{
        "name" => name,
        "description" => description,
        "body" => body,
        "model" => blank_to_nil(args["model"]),
        "category" => blank_to_nil(args["category"]),
        "author" => :orchestrator
      }

      case Templates.save(attrs) do
        {:ok, template} ->
          {:ok, %{"status" => "saved", "name" => template.name, "version" => template.version}}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @doc "Helpful unknown-template error listing the available template names."
  @spec template_not_found(String.t()) :: String.t()
  def template_not_found(name) do
    case Enum.map(Templates.list(), & &1.name) do
      [] -> "unknown subagent_template #{name}; no templates available"
      names -> "unknown subagent_template #{name}; available: #{Enum.join(names, ", ")}"
    end
  end

  @spec template_view(Template.t()) :: map()
  defp template_view(template) do
    %{
      "name" => template.name,
      "description" => template.description,
      "body" => template.body,
      "model" => template.model,
      "category" => template.category,
      "harness" => template.harness,
      "version" => template.version,
      "author" => Atom.to_string(template.author)
    }
  end
end
