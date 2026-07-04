defmodule RepoBuilderWeb.ConsoleLive.TemplatesPanel do
  @moduledoc """
  Agent-templates panel of the console (docs/audit-2026-07.md F3, Phase 3): the
  agent-template settings tab's new/select/save/restore/delete event handlers extracted
  verbatim from `ConsoleLive`. `ConsoleLive` delegates the panel's events here and calls
  the public `Shared.assign_template_rows/1` loader from `mount`.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.Orchestrator.Templates
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(new_template select_template save_agent_template restore_template delete_template)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  # Start a blank new-template form (clears the selection + version history).
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("new_template", _params, socket) do
    {:noreply, assign(socket, selected_template: nil, template_versions: [])}
  end

  # Load a template (current version) into the editor + its version history.
  def handle_event("select_template", %{"name" => name}, socket) do
    {:noreply, select_template(socket, name)}
  end

  # Save a new version of a template (author: operator) and re-select it.
  def handle_event("save_agent_template", params, socket) do
    attrs = %{
      "name" => params["name"],
      "description" => params["description"],
      "body" => params["system_prompt"],
      "model" => Shared.nilify_blank(params["model"] || ""),
      "category" => Shared.nilify_blank(params["category"] || ""),
      "author" => :operator
    }

    case Templates.save(attrs) do
      {:ok, template} ->
        {:noreply,
         socket
         |> Shared.assign_template_rows()
         |> select_template(template.name)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save template (check name/fields)")}
    end
  end

  # Promote an old version to a fresh current one (non-destructive restore).
  def handle_event("restore_template", %{"name" => name, "version" => version}, socket) do
    case Integer.parse(version) do
      {k, _rest} ->
        case Templates.restore(name, k) do
          {:ok, _template} ->
            {:noreply, socket |> Shared.assign_template_rows() |> select_template(name)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not restore version")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid version")}
    end
  end

  # Delete a writable template's history; built-ins are read-only.
  def handle_event("delete_template", %{"name" => name}, socket) do
    case Templates.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(selected_template: nil, template_versions: [])
         |> Shared.assign_template_rows()}

      {:error, :builtin} ->
        {:noreply, put_flash(socket, :error, "Built-in templates are read-only")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete template")}
    end
  end

  # --- private ---

  # Load a template's current version + version history into the editor assigns.
  # A missing template falls back to the blank-form state (flash on error).
  @spec select_template(Socket.t(), String.t()) :: Socket.t()
  defp select_template(socket, name) do
    case Templates.fetch(name) do
      {:ok, template} ->
        assign(socket, selected_template: template, template_versions: Templates.versions(name))

      {:error, _reason} ->
        socket
        |> assign(selected_template: nil, template_versions: [])
        |> put_flash(:error, "Template not found")
    end
  end
end
