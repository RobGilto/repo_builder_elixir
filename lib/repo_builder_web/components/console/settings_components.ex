defmodule RepoBuilderWeb.Console.SettingsComponents do
  @moduledoc """
  Settings panel components: the tabbed settings modal (general / templates /
  cost / prices / stack layers / APIs), the tab-rail button and labeled field
  helpers, and the stack-layers catalog table.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.Console.CostComponents,
    only: [
      project_cost_panel: 1,
      spend_summary_table: 1,
      cost_rollup_table: 1,
      price_catalog_table: 1
    ]

  import RepoBuilderWeb.Console.ExternalApisComponents, only: [external_apis_panel: 1]

  import RepoBuilderWeb.Console.SharedComponents,
    only: [hide_settings: 0, show_log_manager: 1]

  alias RepoBuilder.StackLayers.StackLayer

  attr :settings_tab, :atom,
    default: :general,
    values: [
      :general,
      :appearance,
      :about,
      :prompt,
      :templates,
      :cost_center,
      :default_models,
      :external_apis,
      :logs
    ]

  attr :view_mode, :atom, default: :logs
  attr :chat_width, :atom, default: :sm
  attr :auto_follow?, :boolean, default: true
  attr :show_thinking?, :boolean, default: true
  attr :show_hidden?, :boolean, default: false
  attr :release_notice, :any, default: nil
  attr :harnesses, :list, default: []
  attr :system_prompt, :string, default: ""
  attr :system_prompt_mode, :atom, default: :append, values: [:append, :replace]
  attr :default_system_prompt, :string, default: ""

  attr :reasoning_effort, :atom,
    default: :default,
    values: [:default, :off, :low, :medium, :high, :max]

  attr :reasoning_efforts, :list, default: []
  attr :timezone, :string, default: "UTC"
  attr :timezones, :list, default: []
  attr :template_rows, :list, default: []
  attr :selected_template, :any, default: nil
  attr :template_versions, :list, default: []
  attr :cost_rollups, :list, default: []
  attr :period_spend, :any, default: nil
  attr :project_report, :any, default: nil
  attr :price_rows, :list, default: []
  attr :price_form, :any, default: nil
  attr :editing_price_id, :any, default: nil
  attr :stack_layer_rows, :list, default: []
  attr :stack_layer_form, :any, default: nil
  attr :editing_layer_id, :any, default: nil
  attr :default_model_rows, :list, default: []
  attr :default_model_saved, :boolean, default: false
  attr :user_apis, :list, default: []
  attr :project_apis, :list, default: []
  attr :api_form, :any, default: nil
  attr :editing_api_id, :any, default: nil
  attr :api_secret_names, :any, default: nil
  attr :smart_import, :map, default: %{status: :idle, request_id: nil}
  attr :api_secret_prefill, :map, default: %{scope: nil, name: nil, value: nil}
  attr :active_project_id, :any, default: nil

  @doc """
  Settings modal with a vertical tab rail (General / Appearance / About). Shown and
  hidden client-side like the other modals; the active tab is server-driven via the
  `select_settings_tab` event. Controls reuse the existing toggle events (new element
  ids) so there is no duplicate-id conflict with the header controls.
  """
  @spec settings_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_modal(assigns) do
    ~H"""
    <div
      id="settings-modal"
      class="cns-cmd-overlay"
      style="display:none; align-items: center"
      phx-window-keydown={hide_settings()}
      phx-key="Escape"
    >
      <div
        class="cns-cmd-panel flex flex-col"
        style="max-width: 48rem; height: 80vh; margin-bottom: 0; overflow: hidden"
      >
        <div class="mb-3 flex shrink-0 items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">SETTINGS</span>
          <button type="button" phx-click={hide_settings()} class="cns-chip">Done</button>
        </div>

        <div class="flex min-h-0 flex-1 gap-4" style="min-height: 16rem">
          <nav
            class="cns-no-scrollbar flex w-36 shrink-0 flex-col gap-1 overflow-y-auto border-r pr-2"
            style="border-color: var(--cns-border)"
          >
            <.settings_tab_button tab={:general} active={@settings_tab} label="General" />
            <.settings_tab_button tab={:appearance} active={@settings_tab} label="Appearance" />
            <.settings_tab_button tab={:prompt} active={@settings_tab} label="System Prompt" />
            <.settings_tab_button tab={:templates} active={@settings_tab} label="Agent Templates" />
            <.settings_tab_button tab={:cost_center} active={@settings_tab} label="Cost Center" />
            <.settings_tab_button
              tab={:stack_layers}
              active={@settings_tab}
              label="Stack Layers"
            />
            <.settings_tab_button
              tab={:default_models}
              active={@settings_tab}
              label="Default Models"
            />
            <.settings_tab_button
              tab={:external_apis}
              active={@settings_tab}
              label="Registered APIs"
            />
            <.settings_tab_button tab={:logs} active={@settings_tab} label="Log Database" />
            <.settings_tab_button tab={:about} active={@settings_tab} label="About" />
          </nav>

          <div class="cns-no-scrollbar min-w-0 flex-1 overflow-y-auto pr-1">
            <div :if={@settings_tab == :general} class="flex flex-col gap-4">
              <.settings_field label="View mode">
                <div id="settings-view-toggle" class="cns-toggle" phx-click="toggle_view">
                  <span class={["cns-toggle__seg", @view_mode == :logs && "cns-toggle__seg--active"]}>
                    LOGS
                  </span>
                  <span class={["cns-toggle__seg", @view_mode == :adws && "cns-toggle__seg--active"]}>
                    ADWS
                  </span>
                </div>
              </.settings_field>

              <.settings_field label="Auto-follow chat & stream">
                <button
                  id="settings-auto-follow"
                  type="button"
                  phx-click="toggle_auto_follow"
                  class={["cns-chip", @auto_follow? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @auto_follow?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Show orchestrator thinking">
                <button
                  id="settings-thinking"
                  type="button"
                  phx-click="toggle_thinking"
                  class={["cns-chip", @show_thinking? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @show_thinking?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Reasoning effort">
                <div id="settings-reasoning-effort" class="cns-toggle">
                  <button
                    :for={e <- @reasoning_efforts}
                    type="button"
                    id={"settings-reasoning-effort-#{e}"}
                    phx-click="set_reasoning_effort"
                    phx-value-effort={e}
                    class={["cns-toggle__seg", @reasoning_effort == e && "cns-toggle__seg--active"]}
                  >
                    {e |> Atom.to_string() |> String.upcase()}
                  </button>
                </div>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  How hard the orchestrator's model reasons. DEFAULT keeps each harness's
                  own default (no flag); MAX maps to each harness's top level.
                </p>
              </.settings_field>

              <.settings_field label="Timezone">
                <form id="settings-timezone-form" phx-change="set_timezone" title="Display timezone">
                  <select id="settings-timezone" name="timezone" class="cns-chip" style="width: 12rem">
                    <option :for={tz <- @timezones} value={tz} selected={@timezone == tz}>
                      {tz}
                    </option>
                  </select>
                </form>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Log timestamps render in this timezone (YYYY-MM-DD HH:MM:SS). The
                  setting persists across sessions.
                </p>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :logs} class="flex flex-col gap-4">
              <.settings_field label="Release hidden logs & workflows">
                <div class="flex items-center gap-2">
                  <button
                    id="settings-release-hidden"
                    type="button"
                    phx-click="release_hidden"
                    class="cns-chip"
                  >
                    Release
                  </button>
                  <span
                    :if={@release_notice != nil}
                    id="settings-release-notice"
                    class="text-[0.625rem]"
                    style="color: var(--cns-text-2)"
                  >
                    Released {@release_notice} {if @release_notice == 1, do: "row", else: "rows"}
                  </span>
                </div>
                <div class="text-[0.625rem]" style="color: var(--cns-text-2)">
                  Permanently un-hides everything cleared by the CLEAR actions (the inverse of CLEAR);
                  released rows stay visible across reconnects.
                </div>
              </.settings_field>

              <.settings_field label="Temporarily show cleared rows (peek)">
                <button
                  id="settings-show-hidden"
                  type="button"
                  phx-click="toggle_show_hidden"
                  class={["cns-chip", @show_hidden? && "cns-chip--active cns-chip--hook"]}
                >
                  {if @show_hidden?, do: "ON", else: "OFF"}
                </button>
              </.settings_field>

              <.settings_field label="Manage log rows">
                <button
                  id="open-log-manager"
                  type="button"
                  phx-click={JS.push("open_log_manager") |> show_log_manager()}
                  class="cns-chip cns-chip--active cns-chip--hook"
                >
                  Manage log rows…
                </button>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Open a paginated, filterable inspector to select rows and make them
                  visible/invisible or purge them permanently.
                </p>
              </.settings_field>

              <.settings_field label="Purge ALL log rows (danger)">
                <button
                  id="settings-purge-all-logs"
                  type="button"
                  phx-click="purge_all_logs"
                  data-confirm="Permanently DELETE every log row? This cannot be undone and also clears Cost Center history."
                  class="cns-chip"
                >
                  Purge ALL log rows
                </button>
                <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                  Hard-deletes every <code>agent_logs</code>
                  row. This is permanent and also removes the cost history those rows feed into Cost Center.
                </p>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :appearance} class="flex flex-col gap-4">
              <.settings_field label="Chat width">
                <div class="cns-toggle">
                  <button
                    :for={w <- [:sm, :md, :lg]}
                    type="button"
                    id={"settings-chat-width-#{w}"}
                    phx-click="set_chat_width"
                    phx-value-width={w}
                    class={["cns-toggle__seg", @chat_width == w && "cns-toggle__seg--active"]}
                  >
                    {w |> Atom.to_string() |> String.upcase()}
                  </button>
                </div>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :prompt} class="flex flex-col gap-4">
              <.form
                id="settings-system-prompt-form"
                for={%{}}
                phx-submit="save_system_prompt"
                class="flex flex-col gap-4"
              >
                <.settings_field label="Apply mode">
                  <div class="cns-toggle">
                    <button
                      :for={m <- [:append, :replace]}
                      type="button"
                      id={"settings-system-prompt-mode-#{m}"}
                      phx-click="set_system_prompt_mode"
                      phx-value-mode={m}
                      class={[
                        "cns-toggle__seg",
                        @system_prompt_mode == m && "cns-toggle__seg--active"
                      ]}
                    >
                      {m |> Atom.to_string() |> String.upcase()}
                    </button>
                  </div>
                  <input type="hidden" name="mode" value={@system_prompt_mode} />
                  <p class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
                    APPEND adds your prompt onto the harness default. REPLACE swaps the
                    harness's default coding-agent prompt out entirely — including its
                    built-in tool/safety guidance.
                  </p>
                </.settings_field>

                <.settings_field label="Custom system prompt (blank = generated default)">
                  <textarea
                    id="settings-system-prompt"
                    name="system_prompt"
                    rows="8"
                    class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                    style="border-color: var(--cns-border)"
                    phx-debounce="300"
                  ><%= @system_prompt %></textarea>
                </.settings_field>

                <div class="flex gap-2">
                  <button
                    type="submit"
                    id="settings-system-prompt-save"
                    class="cns-chip cns-chip--active cns-chip--hook"
                  >
                    Save
                  </button>
                  <button
                    type="button"
                    id="settings-system-prompt-reset"
                    phx-click="reset_system_prompt"
                    class="cns-chip"
                  >
                    Reset to default
                  </button>
                </div>
              </.form>

              <.settings_field label="Generated default (preview)">
                <pre
                  id="settings-system-prompt-default"
                  class="max-h-48 overflow-auto whitespace-pre-wrap break-words rounded border p-2 font-mono text-[0.625rem]"
                  style="border-color: var(--cns-border); color: var(--cns-text-2)"
                  phx-no-curly-interpolation
                ><%= @default_system_prompt %></pre>
              </.settings_field>
            </div>

            <div :if={@settings_tab == :templates} class="flex gap-3">
              <div
                class="flex w-40 shrink-0 flex-col gap-1 border-r pr-2"
                style="border-color: var(--cns-border)"
              >
                <button
                  type="button"
                  id="agent-template-new"
                  phx-click="new_template"
                  class={[
                    "cns-chip text-left",
                    is_nil(@selected_template) && "cns-chip--active cns-chip--hook"
                  ]}
                >
                  + New template
                </button>
                <button
                  :for={row <- @template_rows}
                  type="button"
                  id={"agent-template-row-#{row.name}"}
                  phx-click="select_template"
                  phx-value-name={row.name}
                  class={[
                    "cns-chip text-left",
                    template_name(@selected_template) == row.name && "cns-chip--active cns-chip--hook"
                  ]}
                >
                  {row.name} · v{row.version}
                </button>
                <p
                  :if={@template_rows == []}
                  class="text-[0.625rem]"
                  style="color: var(--cns-text-2)"
                >
                  No templates yet.
                </p>
              </div>

              <div class="flex min-w-0 flex-1 flex-col gap-3">
                <.form
                  id="agent-template-form"
                  for={%{}}
                  phx-submit="save_agent_template"
                  class="flex flex-col gap-3"
                >
                  <.settings_field label="Name (kebab-case)">
                    <input
                      id="agent-template-name"
                      name="name"
                      value={template_field(@selected_template, :name)}
                      class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                      style="border-color: var(--cns-border)"
                    />
                  </.settings_field>

                  <.settings_field label="Description">
                    <input
                      id="agent-template-description"
                      name="description"
                      value={template_field(@selected_template, :description)}
                      class="w-full rounded border bg-transparent p-2 text-xs"
                      style="border-color: var(--cns-border)"
                    />
                  </.settings_field>

                  <div class="flex gap-3">
                    <.settings_field label="Model (optional)">
                      <input
                        id="agent-template-model"
                        name="model"
                        value={template_field(@selected_template, :model)}
                        class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                        style="border-color: var(--cns-border)"
                      />
                    </.settings_field>

                    <.settings_field label="Category (optional)">
                      <select
                        id="agent-template-category"
                        name="category"
                        class="w-full rounded border bg-transparent p-2 text-xs"
                        style="border-color: var(--cns-border)"
                      >
                        <option
                          value=""
                          selected={template_field(@selected_template, :category) == ""}
                        >
                          —
                        </option>
                        <option
                          :for={c <- ~w(fast main heavy leader)}
                          value={c}
                          selected={template_field(@selected_template, :category) == c}
                        >
                          {c}
                        </option>
                      </select>
                    </.settings_field>
                  </div>

                  <.settings_field label="System prompt (worker body)">
                    <textarea
                      id="agent-template-body"
                      name="system_prompt"
                      rows="8"
                      class="w-full rounded border bg-transparent p-2 font-mono text-xs"
                      style="border-color: var(--cns-border)"
                    ><%= template_field(@selected_template, :body) %></textarea>
                  </.settings_field>

                  <div class="flex gap-2">
                    <button
                      type="submit"
                      id="agent-template-save"
                      class="cns-chip cns-chip--active cns-chip--hook"
                    >
                      Save new version
                    </button>
                    <button
                      :if={not is_nil(@selected_template)}
                      type="button"
                      id="agent-template-delete"
                      phx-click="delete_template"
                      phx-value-name={template_name(@selected_template)}
                      data-confirm="Delete this template and all its versions?"
                      class="cns-chip"
                    >
                      Delete
                    </button>
                  </div>
                </.form>

                <.settings_field :if={@template_versions != []} label="Version history">
                  <div class="flex flex-col gap-1">
                    <div
                      :for={v <- @template_versions}
                      class="flex items-center justify-between text-xs"
                    >
                      <span style="color: var(--cns-text-2)">v{v.version} · {v.author}</span>
                      <button
                        type="button"
                        id={"agent-template-restore-#{v.version}"}
                        phx-click="restore_template"
                        phx-value-name={template_name(@selected_template)}
                        phx-value-version={v.version}
                        class="cns-chip"
                      >
                        Restore
                      </button>
                    </div>
                  </div>
                </.settings_field>
              </div>
            </div>

            <div :if={@settings_tab == :cost_center} class="flex flex-col gap-4">
              <.project_cost_panel :if={@project_report} report={@project_report} />
              <.spend_summary_table :if={@period_spend} summary={@period_spend} />
              <.cost_rollup_table rollups={@cost_rollups} />
              <.price_catalog_table
                rows={@price_rows}
                form={@price_form}
                editing_price_id={@editing_price_id}
              />
            </div>

            <div :if={@settings_tab == :stack_layers} class="flex flex-col gap-4">
              <.stack_layers_table
                rows={@stack_layer_rows}
                form={@stack_layer_form}
                editing_layer_id={@editing_layer_id}
              />
            </div>

            <div :if={@settings_tab == :default_models} class="flex flex-col gap-3">
              <div class="flex items-center justify-between">
                <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
                  DEFAULT MODELS — what new projects inherit
                </span>
                <span
                  :if={@default_model_saved}
                  class="cns-chip"
                  style="color: var(--cns-green, #4ade80)"
                >
                  Saved ✓
                </span>
              </div>

              <p class="text-[0.625rem]" style="color: var(--cns-text-2)">
                Set the global default harness/provider/model per worker tier. A newly
                registered project's orchestrator is seeded from this roster, and any tier a
                project leaves unset inherits it. Per-project overrides always win.
              </p>

              <form
                :for={row <- @default_model_rows}
                id={"default-model-#{row.category}"}
                phx-change="set_default_agent_model"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="category" value={row.category} />
                <span
                  class="w-16 text-xs font-semibold uppercase"
                  style="color: var(--cns-text-1)"
                >
                  {row.category}
                </span>

                <select name="harness" class="cns-chip" style="width: 8rem">
                  <option value="" selected={row.harness in [nil, ""]}>harness…</option>
                  <option :for={h <- row.harness_options} value={h} selected={row.harness == h}>
                    {h}
                  </option>
                </select>

                <select
                  name="provider"
                  class="cns-chip"
                  style="width: 9rem"
                  disabled={row.harness in [nil, ""]}
                >
                  <option value="" selected={row.provider in [nil, ""]}>provider…</option>
                  <option :for={p <- row.provider_options} value={p} selected={row.provider == p}>
                    {p}
                  </option>
                </select>

                <select
                  name="model"
                  class="cns-chip"
                  style="width: 13rem"
                  disabled={row.harness in [nil, ""]}
                >
                  <option value="" selected={row.model in [nil, ""]}>no default…</option>
                  <option :for={m <- row.model_options} value={m} selected={row.model == m}>
                    {m}
                  </option>
                </select>
              </form>
            </div>

            <div :if={@settings_tab == :external_apis}>
              <.external_apis_panel
                user_apis={@user_apis}
                project_apis={@project_apis}
                api_form={@api_form}
                editing_api_id={@editing_api_id}
                api_secret_names={@api_secret_names}
                smart_import={@smart_import}
                api_secret_prefill={@api_secret_prefill}
                active_project_id={@active_project_id}
              />
            </div>

            <div :if={@settings_tab == :about} class="flex flex-col gap-2 text-xs">
              <div
                class="text-[0.625rem] font-semibold uppercase"
                style="color: var(--cns-text-2)"
              >
                Registered harnesses
              </div>
              <div class="flex flex-wrap gap-1">
                <span :for={h <- @harnesses} class="cns-chip">{h}</span>
              </div>
              <p class="mt-2 text-[0.625rem]" style="color: var(--cns-text-2)">
                Orchestration Console — repo_builder. Deterministic orchestration of
                supervised AI harness CLIs.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  @doc "One button in the settings vertical tab rail."
  @spec settings_tab_button(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_settings_tab"
      phx-value-tab={@tab}
      class={["cns-chip text-left", @tab == @active && "cns-chip--active cns-chip--hook"]}
    >
      {@label}
    </button>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  @doc "A labeled settings row (label above its control)."
  @spec settings_field(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        {@label}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # --- stack layers catalog (stack-layers subsystem) ---

  attr :rows, :list, required: true
  attr :form, :any, required: true
  attr :editing_layer_id, :any, default: nil

  @doc """
  Editable Stack Layers catalog (stack-layers subsystem): a create/edit form plus the
  current typed layers with per-row Edit + (confirmed) Delete. Each layer's `reasoning`
  is the worker-facing guardrail injected into the stack contract. Operator edits persist
  to `stack_layers` and mark the row `:manual` (preserved across re-seed).
  """
  @spec stack_layers_table(map()) :: Phoenix.LiveView.Rendered.t()
  def stack_layers_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Stack layers (typed, mix &amp; match per project)
      </div>

      <.form
        :if={@form}
        id="stack-layer-form"
        for={@form}
        phx-submit="save_layer"
        class="flex flex-wrap items-end gap-2"
      >
        <div
          class="w-full text-[0.625rem] font-semibold uppercase"
          style="color: var(--cns-text-2)"
        >
          <span :if={@editing_layer_id}>Editing {@form[:name].value}</span>
          <span :if={!@editing_layer_id}>New layer</span>
        </div>
        <.input :if={@editing_layer_id} field={@form[:id]} type="hidden" />
        <.input
          field={@form[:layer_type]}
          label="Type"
          type="select"
          options={layer_type_options()}
          class="cns-input w-28"
        />
        <.input field={@form[:name]} label="Name" class="cns-input w-36" />
        <.input field={@form[:language]} label="Language" class="cns-input w-28" />
        <.input
          field={@form[:reasoning]}
          label="Reasoning (worker guardrail)"
          type="textarea"
          class="cns-input w-full"
        />
        <button id="stack-layer-form-submit" type="submit" class="cns-chip">Save</button>
        <button
          :if={@editing_layer_id}
          id="stack-layer-cancel"
          type="button"
          phx-click="cancel_layer_edit"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>

      <table id="stack-layers-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Type</th>
            <th class="py-1 pr-2 text-left font-medium">Name</th>
            <th class="py-1 pr-2 text-left font-medium">Language</th>
            <th class="py-1 pr-2 text-left font-medium">Reasoning</th>
            <th class="py-1 pr-2 text-right font-medium">Source</th>
            <th class="py-1"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={l <- @rows}
            id={"stack-layer-row-#{l.id}"}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{l.layer_type}</td>
            <td class="py-1 pr-2">{l.name}</td>
            <td class="py-1 pr-2">{l.language}</td>
            <td class="py-1 pr-2">{reasoning_excerpt(l.reasoning)}</td>
            <td class="py-1 pr-2 text-right">{l.source}</td>
            <td class="py-1 text-right">
              <button
                type="button"
                id={"stack-layer-edit-#{l.id}"}
                phx-click="edit_layer"
                phx-value-id={l.id}
                class="cns-chip"
              >
                Edit
              </button>
              <button
                type="button"
                id={"stack-layer-delete-#{l.id}"}
                phx-click="delete_layer"
                phx-value-id={l.id}
                data-confirm="Delete this layer? It is removed from every project that selected it."
                class="cns-chip"
              >
                ✕
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @spec layer_type_options() :: [{String.t(), String.t()}]
  defp layer_type_options do
    Enum.map(StackLayer.layer_types(), fn type ->
      {type |> Atom.to_string() |> String.capitalize(), Atom.to_string(type)}
    end)
  end

  @spec reasoning_excerpt(String.t() | nil) :: String.t()
  defp reasoning_excerpt(nil), do: ""

  defp reasoning_excerpt(reasoning) when is_binary(reasoning) do
    if String.length(reasoning) > 80, do: String.slice(reasoning, 0, 80) <> "…", else: reasoning
  end

  # Read a string-coerced field off the selected `Template` struct for a form value,
  # tolerating `nil` (the "+ New" blank-form state) and nil optional fields.
  @spec template_field(RepoBuilder.Orchestrator.Template.t() | nil, atom()) :: String.t()
  defp template_field(nil, _field), do: ""

  defp template_field(template, field) do
    case Map.get(template, field) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  # The name of the selected template, or `nil` for the blank-form state.
  @spec template_name(RepoBuilder.Orchestrator.Template.t() | nil) :: String.t() | nil
  defp template_name(nil), do: nil
  defp template_name(template), do: template.name
end
