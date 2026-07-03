defmodule RepoBuilderWeb.ConsoleLive.ExternalApisPanel do
  @moduledoc """
  External-APIs panel of the console (docs/audit-2026-07.md F3, Phase 3): the
  register/edit/delete/deposit-secret/smart-import event handlers extracted verbatim
  from `ConsoleLive`, plus the panel's assign loaders. `ConsoleLive` delegates the
  panel's events here and calls the public loaders from `mount`/`handle_info`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.{ExternalApis, Orchestrators, Secrets}
  alias RepoBuilder.ExternalApis.{ImportResult, SmartImport}
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(register_api edit_api cancel_edit_api update_api delete_api deposit_api_secret smart_import_api)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("register_api", %{"api" => params}, socket) do
    params = normalize_api_params(params, socket)

    case ExternalApis.create(params) do
      {:ok, api} ->
        {:noreply,
         socket
         |> put_flash(:info, "Registered API #{api.name}")
         |> assign(:api_form, blank_api_form())
         |> assign(:editing_api_id, nil)
         |> load_external_apis()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :api_form, to_form(changeset, as: :api))}
    end
  end

  def handle_event("edit_api", %{"id" => id}, socket) do
    case ExternalApis.get(id) do
      {:ok, api} ->
        {:noreply,
         socket
         |> assign(:editing_api_id, api.id)
         |> assign(:api_form, api_form_from(api))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_api", _params, socket) do
    {:noreply, socket |> assign(:editing_api_id, nil) |> assign(:api_form, blank_api_form())}
  end

  def handle_event("update_api", %{"_id" => id, "api" => params}, socket) do
    with {:ok, api} <- ExternalApis.get(id),
         {:ok, updated} <- ExternalApis.update(api, normalize_api_params(params, socket)) do
      {:noreply,
       socket
       |> put_flash(:info, "Updated API #{updated.name}")
       |> assign(:editing_api_id, nil)
       |> assign(:api_form, blank_api_form())
       |> load_external_apis()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :api_form, to_form(changeset, as: :api))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_api", %{"id" => id}, socket) do
    :ok = ExternalApis.delete(id)
    {:noreply, socket |> put_flash(:info, "Deleted API") |> load_external_apis()}
  end

  def handle_event("deposit_api_secret", %{"scope" => scope} = params, socket) do
    name = String.trim(params["name"] || "")
    value = params["value"] || ""
    project_id = secret_scope_id(scope, socket)

    case Secrets.put_secret(project_id, name, value) do
      {:ok, _secret} ->
        {:noreply, socket |> put_flash(:info, "Deposited secret #{name}") |> load_external_apis()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not deposit secret: #{secret_error(changeset)}")}
    end
  end

  # MCP smart import (issue-external-api-mcp-provisioning): run the deterministic parser
  # synchronously (auto-register or pre-fill); on free-form input dispatch the Fast agent
  # and flip to :running, applying its async reply in ConsoleLive's handle_info/2.
  def handle_event("smart_import_api", %{"blob" => blob}, socket) do
    case SmartImport.import(current_orchestrator(socket), blob) do
      {:ok, %ImportResult{} = result} ->
        {:noreply, apply_import_result(socket, result)}

      {:ok, {:async, request_id}} ->
        {:noreply, assign(socket, :smart_import, %{status: :running, request_id: request_id})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :smart_import, %{
           status: {:error, smart_import_error(reason)},
           request_id: nil
         })}
    end
  end

  # Load the two scoped registration lists + the masked set of present vault secret names
  # (platform + active project) so the panel can flag whether a referenced secret exists.
  @spec load_external_apis(Socket.t()) :: Socket.t()
  def load_external_apis(socket) do
    project_id = socket.assigns[:active_project_id]

    secret_names =
      (Secrets.list_names(nil) ++ Secrets.list_names(project_id))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assign(socket,
      user_apis: ExternalApis.list_for_scope(nil),
      project_apis: if(project_id, do: ExternalApis.list_for_scope(project_id), else: []),
      api_secret_names: secret_names
    )
  end

  @spec blank_api_form() :: Phoenix.HTML.Form.t()
  def blank_api_form do
    to_form(ExternalApis.ExternalApi.changeset(%ExternalApis.ExternalApi{}, %{}), as: :api)
  end

  # Apply a smart-import ImportResult: a high-confidence :register draft is created via the
  # existing write path (changeset errors fall back to a pre-filled form); a :question
  # pre-fills the form and shows the clarifying banner. A staged secret pre-fills the
  # Deposit form in both cases (never written to the row).
  @spec apply_import_result(Socket.t(), ImportResult.t()) :: Socket.t()
  def apply_import_result(socket, %ImportResult{action: :register} = result) do
    params = normalize_api_params(result.api_params, socket)

    case ExternalApis.create(params) do
      {:ok, api} ->
        socket
        |> put_flash(:info, "Imported API #{api.name}")
        |> assign(:editing_api_id, nil)
        |> assign(:api_form, blank_api_form())
        |> assign(:smart_import, %{status: :idle, request_id: nil})
        |> stage_secret_prefill(result)
        |> load_external_apis()

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:editing_api_id, nil)
        |> assign(:api_form, to_form(changeset, as: :api))
        |> assign(:smart_import, %{
          status:
            {:question, "Review the draft below — some fields need fixing before it registers."},
          request_id: nil
        })
        |> stage_secret_prefill(result)
    end
  end

  def apply_import_result(socket, %ImportResult{action: :question} = result) do
    changeset = ExternalApis.ExternalApi.changeset(%ExternalApis.ExternalApi{}, result.api_params)

    socket
    |> assign(:editing_api_id, nil)
    |> assign(:api_form, to_form(changeset, as: :api))
    |> assign(:smart_import, %{
      status: {:question, result.question || "Please clarify."},
      request_id: nil
    })
    |> stage_secret_prefill(result)
  end

  @spec smart_import_error(term()) :: String.t()
  def smart_import_error(:no_fast_agent), do: Shared.no_fast_agent_message()

  def smart_import_error(:no_orchestrator),
    do:
      "No orchestrator available to interpret free-form input — paste an MCP config JSON instead."

  def smart_import_error(:empty), do: "Paste an MCP config or a description first."

  def smart_import_error(:bad_agent_reply),
    do: "The Fast agent's reply could not be parsed — try rephrasing."

  def smart_import_error(:timeout), do: "The Fast agent timed out before replying."

  def smart_import_error(_reason),
    do: "Smart import failed — paste an MCP config JSON or try again."

  # --- private ---

  # Stage a parser-extracted token into the Deposit-a-secret form (name + value). The value
  # lives only in this transient assign for one-click deposit — never on the registry row.
  @spec stage_secret_prefill(Socket.t(), ImportResult.t()) :: Socket.t()
  defp stage_secret_prefill(socket, %ImportResult{secret_name: name} = result)
       when is_binary(name) do
    scope = if socket.assigns[:active_project_id], do: "project", else: "user"
    assign(socket, :api_secret_prefill, %{scope: scope, name: name, value: result.secret_value})
  end

  defp stage_secret_prefill(socket, _result), do: socket

  @spec api_form_from(ExternalApis.ExternalApi.t()) :: Phoenix.HTML.Form.t()
  defp api_form_from(api) do
    to_form(ExternalApis.ExternalApi.changeset(api, %{}), as: :api)
  end

  # Coerce the register/edit form params into changeset-ready shape: the `project_id`
  # comes from the chosen scope (nil = platform/user scope; the active project otherwise),
  # and the comma/newline list fields are split into string arrays.
  @spec normalize_api_params(map(), Socket.t()) :: map()
  defp normalize_api_params(params, socket) do
    project_id = secret_scope_id(params["scope"], socket)

    params
    |> Map.put("project_id", project_id)
    |> Map.update("args", [], &split_list/1)
    |> Map.update("doc_urls", [], &split_list/1)
    |> Map.update("allowed_tools", [], &split_list/1)
  end

  # nil for the platform/user scope, the active project id for project scope.
  @spec secret_scope_id(String.t() | nil, Socket.t()) :: Ecto.UUID.t() | nil
  defp secret_scope_id("project", socket), do: socket.assigns[:active_project_id]
  defp secret_scope_id(_user_or_nil, _socket), do: nil

  # Split a comma/newline-separated text field into a trimmed, non-empty string list.
  @spec split_list(term()) :: [String.t()]
  defp split_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_list(value) when is_list(value), do: value
  defp split_list(_value), do: []

  @spec secret_error(Ecto.Changeset.t()) :: String.t()
  defp secret_error(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end

  # The orchestrator backing the active console, or nil — used by the smart-import Fast
  # fallback (the deterministic path needs no orchestrator).
  @spec current_orchestrator(Socket.t()) :: RepoBuilder.Orchestrator.Orchestrator.t() | nil
  defp current_orchestrator(socket) do
    with id when is_binary(id) <- socket.assigns[:orchestrator_id],
         {:ok, orchestrator} <- Orchestrators.fetch(id) do
      orchestrator
    else
      _other -> nil
    end
  end
end
