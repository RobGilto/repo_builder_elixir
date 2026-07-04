defmodule RepoBuilderWeb.Console.ExternalApisComponents do
  @moduledoc """
  External-APIs panel components: the registry panel (form + user/project
  lists), the smart-import box + status, and the API row/error sub-components.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  alias RepoBuilder.ExternalApis.ExternalApi

  attr :user_apis, :list, default: []
  attr :project_apis, :list, default: []
  attr :api_form, :any, required: true
  attr :editing_api_id, :any, default: nil
  attr :api_secret_names, :any, default: nil
  attr :smart_import, :map, default: %{status: :idle, request_id: nil}
  attr :api_secret_prefill, :map, default: %{scope: nil, name: nil, value: nil}
  attr :active_project_id, :any, default: nil

  @doc """
  Registered external APIs / MCP providers panel (issue-external-api-mcp-provisioning):
  two scoped lists (user/platform + active project) the orchestrator may transfer to
  workers, plus a register/edit form and a vault secret-deposit field. The token is never
  shown — only a "secret present?" hint derived from the masked vault names.
  """
  @spec external_apis_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def external_apis_panel(assigns) do
    assigns =
      assign(assigns,
        transports: ExternalApi.transports(),
        auth_schemes: ExternalApi.auth_schemes()
      )

    ~H"""
    <div id="external-apis-panel" class="flex flex-col gap-4">
      <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
        REGISTERED APIs — capabilities the orchestrator may delegate to workers
      </span>
      <p class="text-[0.625rem]" style="color: var(--cns-text-2)">
        Register an external API / MCP server once; the orchestrator transfers it to a
        worker on demand (it never calls these itself). The auth token lives only in the
        encrypted vault — the registration holds the secret NAME, never the value.
      </p>

      <.smart_import_box smart_import={@smart_import} />

      <div class="grid grid-cols-2 gap-4">
        <div>
          <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
            User scope (all orchestrators)
          </div>
          <ul id="api-list-user" class="mt-1 space-y-1">
            <.api_row
              :for={api <- @user_apis}
              api={api}
              present?={secret_present?(@api_secret_names, api)}
            />
            <li :if={@user_apis == []} class="text-xs" style="color: var(--cns-text-3)">
              None registered.
            </li>
          </ul>
        </div>

        <div>
          <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
            Project scope (this project's orchestrator)
          </div>
          <ul id="api-list-project" class="mt-1 space-y-1">
            <.api_row
              :for={api <- @project_apis}
              api={api}
              present?={secret_present?(@api_secret_names, api)}
            />
            <li :if={@project_apis == []} class="text-xs" style="color: var(--cns-text-3)">
              {if @active_project_id,
                do: "None registered for this project.",
                else: "Select a project to register a project-scope API."}
            </li>
          </ul>
        </div>
      </div>

      <.form
        :let={f}
        for={@api_form}
        id="register-api-form"
        phx-submit={if @editing_api_id, do: "update_api", else: "register_api"}
        class="flex flex-col gap-2 border-t pt-3"
        style="border-color: var(--cns-border)"
      >
        <input :if={@editing_api_id} type="hidden" name="_id" value={@editing_api_id} />

        <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
          {if @editing_api_id, do: "Edit registration", else: "Register a new API"}
        </div>

        <div class="grid grid-cols-2 gap-2">
          <label class="flex flex-col gap-1 text-xs">
            Name (MCP server key)
            <input
              name="api[name]"
              value={Phoenix.HTML.Form.input_value(f, :name)}
              class="cns-chip"
              placeholder="pixellab"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Scope
            <select name="api[scope]" class="cns-chip">
              <option value="user" selected={is_nil(Phoenix.HTML.Form.input_value(f, :project_id))}>
                User (all orchestrators)
              </option>
              <option
                value="project"
                selected={not is_nil(Phoenix.HTML.Form.input_value(f, :project_id))}
                disabled={is_nil(@active_project_id)}
              >
                Project (this project)
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Provider (label)
            <input
              name="api[provider]"
              value={Phoenix.HTML.Form.input_value(f, :provider)}
              class="cns-chip"
              placeholder="Pixellab"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Transport
            <select name="api[transport]" class="cns-chip">
              <option
                :for={t <- @transports}
                value={t}
                selected={to_string(Phoenix.HTML.Form.input_value(f, :transport)) == to_string(t)}
              >
                {t}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-xs">
            URL (http/sse)
            <input
              name="api[url]"
              value={Phoenix.HTML.Form.input_value(f, :url)}
              class="cns-chip"
              placeholder="https://api.pixellab.ai/mcp"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Command (stdio)
            <input
              name="api[command]"
              value={Phoenix.HTML.Form.input_value(f, :command)}
              class="cns-chip"
              placeholder="npx"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Args (stdio, comma-separated)
            <input
              name="api[args]"
              value={join_list(Phoenix.HTML.Form.input_value(f, :args))}
              class="cns-chip"
              placeholder="-y, firecrawl-mcp"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Auth scheme
            <select name="api[auth_scheme]" class="cns-chip">
              <option
                :for={s <- @auth_schemes}
                value={s}
                selected={to_string(Phoenix.HTML.Form.input_value(f, :auth_scheme)) == to_string(s)}
              >
                {s}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Auth header (override)
            <input
              name="api[auth_header]"
              value={Phoenix.HTML.Form.input_value(f, :auth_header)}
              class="cns-chip"
              placeholder="Authorization"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Secret name (vault reference)
            <input
              name="api[secret_name]"
              value={Phoenix.HTML.Form.input_value(f, :secret_name)}
              class="cns-chip"
              placeholder="PIXELLAB_API_KEY"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Allowed tools (comma-separated)
            <input
              name="api[allowed_tools]"
              value={join_list(Phoenix.HTML.Form.input_value(f, :allowed_tools))}
              class="cns-chip"
              placeholder="mcp__pixellab__*"
            />
          </label>
          <label class="flex flex-col gap-1 text-xs">
            Doc URLs (comma-separated)
            <input
              name="api[doc_urls]"
              value={join_list(Phoenix.HTML.Form.input_value(f, :doc_urls))}
              class="cns-chip"
              placeholder="https://api.pixellab.ai/mcp/docs"
            />
          </label>
        </div>

        <label class="flex flex-col gap-1 text-xs">
          Description (one line, shown to the orchestrator)
          <input
            name="api[description]"
            value={Phoenix.HTML.Form.input_value(f, :description)}
            class="cns-chip"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs">
          Instructions (how a worker should use it) <textarea
            name="api[instructions]"
            class="cns-chip"
            rows="2"
          >{Phoenix.HTML.Form.input_value(f, :instructions)}</textarea>
        </label>

        <.api_errors form={f} />

        <div class="flex items-center gap-2">
          <button type="submit" class="rounded bg-cyan-700 px-3 py-1 text-xs">
            {if @editing_api_id, do: "Update", else: "Register"}
          </button>
          <button
            :if={@editing_api_id}
            type="button"
            phx-click="cancel_edit_api"
            class="cns-chip"
          >
            Cancel
          </button>
        </div>
      </.form>

      <form
        id="deposit-api-secret-form"
        phx-submit="deposit_api_secret"
        class="flex flex-wrap items-end gap-2 border-t pt-3"
        style="border-color: var(--cns-border)"
      >
        <div
          class="text-[0.625rem] font-semibold uppercase"
          style="color: var(--cns-text-2); width: 100%"
        >
          Deposit a secret into the vault
        </div>
        <label class="flex flex-col gap-1 text-xs">
          Scope
          <select name="scope" class="cns-chip">
            <option value="user" selected={@api_secret_prefill[:scope] == "user"}>
              User (platform)
            </option>
            <option
              value="project"
              disabled={is_nil(@active_project_id)}
              selected={@api_secret_prefill[:scope] == "project"}
            >
              Project
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-xs">
          Secret name
          <input
            name="name"
            class="cns-chip"
            placeholder="PIXELLAB_API_KEY"
            value={@api_secret_prefill[:name]}
          />
        </label>
        <label class="flex flex-col gap-1 text-xs">
          Value
          <input
            name="value"
            type="password"
            class="cns-chip"
            placeholder="token"
            value={@api_secret_prefill[:value]}
          />
        </label>
        <button type="submit" class="rounded bg-cyan-700 px-3 py-1 text-xs">Deposit</button>
      </form>
    </div>
    """
  end

  attr :smart_import, :map, default: %{status: :idle, request_id: nil}

  @doc """
  Smart import box (issue-external-api-mcp-provisioning): a textarea where the operator
  pastes an MCP config (mcpServers JSON / a single server object) or a description. The
  deterministic parser registers/pre-fills well-formed JSON instantly; fuzzy input is
  interpreted by the orchestrator's Fast tier. Tokens are stripped locally and staged for
  the vault — never stored on the row. `@smart_import.status` drives the status banner.
  """
  @spec smart_import_box(map()) :: Phoenix.LiveView.Rendered.t()
  def smart_import_box(assigns) do
    ~H"""
    <div
      id="smart-import-box"
      class="flex flex-col gap-2 rounded border p-3"
      style="border-color: var(--cns-border)"
    >
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Smart import (Fast agent)
      </div>
      <form id="smart-import-form" phx-submit="smart_import_api" class="flex flex-col gap-2">
        <textarea
          name="blob"
          rows="4"
          class="cns-chip font-mono text-xs"
          placeholder="Paste an MCP config (mcpServers JSON, a single server object) or describe the server.\nTokens are stripped locally and staged for the vault — never stored on the row."
        ></textarea>
        <div class="flex items-center gap-2">
          <button type="submit" class="rounded bg-cyan-700 px-3 py-1 text-xs">
            Parse with Fast agent
          </button>
          <.smart_import_status status={@smart_import.status} />
        </div>
      </form>
    </div>
    """
  end

  attr :status, :any, required: true

  @doc false
  @spec smart_import_status(map()) :: Phoenix.LiveView.Rendered.t()
  def smart_import_status(%{status: :running} = assigns) do
    ~H"""
    <span id="smart-import-status" class="text-xs" style="color: var(--cns-text-3)">Parsing…</span>
    """
  end

  def smart_import_status(%{status: {:question, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <span id="smart-import-status" class="text-xs" style="color: var(--cns-cyan)">{@text}</span>
    """
  end

  def smart_import_status(%{status: {:error, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <span id="smart-import-status" class="text-xs" style="color: var(--cns-red, #f87171)">
      {@text}
    </span>
    """
  end

  def smart_import_status(assigns) do
    ~H"""
    <span id="smart-import-status" class="sr-only">idle</span>
    """
  end

  attr :api, :any, required: true
  attr :present?, :boolean, default: false

  @doc false
  @spec api_row(map()) :: Phoenix.LiveView.Rendered.t()
  def api_row(assigns) do
    ~H"""
    <li id={"api-row-#{@api.id}"} class="flex items-center justify-between gap-2 text-xs">
      <span class="flex min-w-0 flex-col">
        <span class="font-mono">{@api.name}</span>
        <span class="text-[0.625rem]" style="color: var(--cns-text-3)">
          {@api.transport}{if @api.secret_name,
            do: " · #{@api.secret_name} #{if @present?, do: "✓", else: "(missing)"}"}
        </span>
      </span>
      <span class="flex items-center gap-1">
        <button type="button" phx-click="edit_api" phx-value-id={@api.id} class="cns-chip">edit</button>
        <button
          type="button"
          phx-click="delete_api"
          phx-value-id={@api.id}
          data-confirm={"Delete #{@api.name}?"}
          class="cns-chip"
        >
          ✕
        </button>
      </span>
    </li>
    """
  end

  attr :form, :any, required: true

  @doc false
  @spec api_errors(map()) :: Phoenix.LiveView.Rendered.t()
  def api_errors(assigns) do
    ~H"""
    <ul :if={@form.errors != []} class="text-xs" style="color: var(--cns-red, #f87171)">
      <li :for={{field, {msg, _opts}} <- @form.errors}>{field} {msg}</li>
    </ul>
    """
  end

  # Whether the API's referenced vault secret is present (masked names only — never the
  # value). `nil`/missing secret_name or no auth ⇒ not flagged.
  @spec secret_present?(MapSet.t() | nil, ExternalApi.t()) :: boolean()
  defp secret_present?(%MapSet{} = names, %{secret_name: secret}) when is_binary(secret),
    do: MapSet.member?(names, secret)

  defp secret_present?(_names, _api), do: false

  # Render a JSONB string-array field back into a comma-separated text input value.
  @spec join_list(term()) :: String.t()
  defp join_list(list) when is_list(list), do: Enum.join(list, ", ")
  defp join_list(_other), do: ""
end
