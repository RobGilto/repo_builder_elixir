defmodule RepoBuilderWeb.Console.AdwBuilderComponents do
  @moduledoc """
  ⌘K command-palette / ADW-builder components: the bottom-anchored global
  command-input modal (command mode + ADW builder mode), the palette chip row,
  and the chip/autocomplete/step-label helpers.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.Console.SharedComponents, only: [hide_command: 0, hide_command: 1]

  alias RepoBuilder.Agents.Agent

  # A normalized prompt-palette chip. `:status` is optional — file-derived chips
  # (slash/agents/adws) omit it; live-agent chips carry the worker's runtime status
  # so the row can render a status dot.
  @type chip :: %{
          required(:token) => String.t(),
          required(:label) => String.t(),
          required(:source) => atom(),
          required(:description) => String.t() | nil,
          optional(:status) => atom()
        }

  attr :slash_commands, :list, default: [], doc: "file-derived %Definitions.SlashCommand{} list"
  attr :agent_defs, :list, default: [], doc: "file-derived %Definitions.Agent{} list"
  attr :adws, :list, default: [], doc: "file-derived %Definitions.Adw{} list"
  attr :working_dir, :string, default: ""
  attr :uploads, :map, required: true
  attr :adw_builder?, :boolean, default: false
  attr :adw_steps, :list, default: []
  attr :adw_name, :string, default: ""
  attr :adw_flavor, :atom, default: :iso, values: [:iso, :local_iso, :direct]
  attr :adw_spec, :string, default: ""
  attr :adw_prompt, :string, default: ""
  attr :adw_combos, :list, default: []
  attr :adw_loadable, :list, default: []
  attr :adw_selected_combo, :string, default: ""
  attr :adw_harness, :string, default: ""
  attr :harness_names, :list, default: []
  attr :agents, :list, default: [], doc: "live %Agent{} workers shown in the left rail"
  attr :statuses, :map, default: %{}, doc: "agent id => live runtime status"

  attr :palette_source_tab, :atom,
    default: :base,
    values: [:base, :project],
    doc:
      "active source tab for the file-derived palette: :base (platform repo) | :project (overlay)"

  @doc "Bottom-anchored ⌘K command-input modal with a system-info panel (harnesses/agents/example ADW)."
  @spec global_command_input(map()) :: Phoenix.LiveView.Rendered.t()
  def global_command_input(assigns) do
    ~H"""
    <div
      id="command-input"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_command()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel">
        <%!-- Header: title + mode toggle + close --%>
        <div class="mb-2 flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
              {if @adw_builder?, do: "ADW BUILDER", else: "COMMAND (⌘K)"}
            </span>
            <button
              type="button"
              phx-click="toggle_adw_builder"
              class={["cns-chip", @adw_builder? && "cns-chip--active"]}
              title="Switch to ADW Builder mode"
            >
              ADW
            </button>
          </div>
          <div class="flex items-center gap-2">
            <label
              for={@uploads.attachments.ref}
              class="cns-chip cursor-pointer"
              title="Attach files"
            >
              📎 <.live_file_input upload={@uploads.attachments} form="command-form" class="sr-only" />
            </label>
            <button id="prompt-close" type="button" phx-click={hide_command()} class="cns-chip">
              Esc
            </button>
          </div>
        </div>

        <%!-- COMMAND MODE --%>
        <div :if={not @adw_builder?}>
          <div class="mb-2 flex items-center gap-2 text-[0.625rem]" style="color: var(--cns-text-2)">
            <span class="font-semibold">CWD</span>
            <button
              type="button"
              id="cmd-working-dir"
              phx-click="open_dir_picker"
              class="cns-cmd-chip min-w-0 max-w-full truncate font-mono"
              title="Choose the working directory the orchestrator and its workers run in"
            >
              📁 {if @working_dir in [nil, ""], do: "isolated workspace", else: @working_dir}
            </button>
            <button
              :if={@working_dir not in [nil, ""]}
              type="button"
              id="cmd-working-dir-clear"
              phx-click="clear_working_dir"
              class="cns-cmd-chip"
              title="Clear — each agent gets its own isolated scratch workspace"
            >
              ✕
            </button>
          </div>

          <div style="position: relative">
            <form
              id="command-form"
              phx-change="validate_attachments"
              phx-submit={JS.push("run_command") |> hide_command()}
            >
              <div
                id="cmd-drop-zone"
                phx-drop-target={@uploads.attachments.ref}
                class="cns-cmd-drop-zone"
              >
                <textarea
                  id="command-textarea"
                  name="command"
                  rows="3"
                  placeholder="Type a command… (Enter ↵ send · Shift+Enter newline · drag & drop or paste images)"
                  class="cns-cmd-textarea"
                  phx-hook="CommandAutocomplete"
                  data-autocomplete={autocomplete_json(@slash_commands, @agent_defs, @adws)}
                ></textarea>
              </div>

              <div :if={@uploads.attachments.entries != []} class="mt-2 flex flex-wrap gap-2">
                <div :for={entry <- @uploads.attachments.entries} class="cns-attachment-entry">
                  <.live_img_preview
                    :if={String.starts_with?(entry.client_type, "image/")}
                    entry={entry}
                    class="cns-attachment-thumb"
                  />
                  <span
                    :if={not String.starts_with?(entry.client_type, "image/")}
                    class="cns-attachment-name"
                  >
                    {entry.client_name}
                  </span>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    class="cns-attachment-remove"
                    aria-label="Remove"
                  >
                    ✕
                  </button>
                  <p
                    :for={err <- upload_errors(@uploads.attachments, entry)}
                    class="cns-attachment-error"
                  >
                    {upload_error_to_string(err)}
                  </p>
                </div>
              </div>
            </form>

            <div
              id="autocomplete-dropdown"
              role="listbox"
              aria-label="Autocomplete suggestions"
              style="display:none; position:absolute; top:100%; left:0; right:0; z-index:50;
                   background:var(--cns-surface-2); border:1px solid var(--cns-border);
                   border-radius:4px; max-height:14rem; overflow-y:auto; margin-top:2px"
            >
            </div>
          </div>

          <%!-- Source-scoped palette (issue palette-source-tabs): vertical BASE / PROJECT tabs.
                BASE = artifacts from the platform repo's `.claude/` (source :app); PROJECT =
                artifacts from the active working dir's `.claude/` overlay (source :working_dir).
                Live workers are runtime state, not a repo artifact, so they stay below the tabs. --%>
          <div class="mt-3 text-[0.625rem]">
            <div class="flex gap-3">
              <div class="flex shrink-0 flex-col gap-1">
                <button
                  type="button"
                  id="palette-tab-base"
                  phx-click="set_palette_tab"
                  phx-value-tab="base"
                  class={[
                    "cns-cmd-chip w-full text-left",
                    @palette_source_tab == :base && "cns-chip--active"
                  ]}
                  title="Artifacts from the platform repo (.claude/, priv, adws)"
                >
                  base ({palette_source_count(@slash_commands, @agent_defs, @adws, :app)})
                </button>
                <button
                  type="button"
                  id="palette-tab-project"
                  phx-click="set_palette_tab"
                  phx-value-tab="project"
                  class={[
                    "cns-cmd-chip w-full text-left",
                    @palette_source_tab == :project && "cns-chip--active"
                  ]}
                  title="Artifacts from the active project's working directory (.claude/)"
                >
                  project ({palette_source_count(@slash_commands, @agent_defs, @adws, :working_dir)})
                </button>
              </div>

              <div class="flex min-w-0 flex-1 flex-col gap-2">
                <div :if={@palette_source_tab == :base} class="flex flex-col gap-2">
                  <.palette_row
                    id="slash-base"
                    label="SLASH"
                    chips={source_chips(:slash_command, @slash_commands, :app)}
                    empty_hint="none — add `.claude/commands/<name>.md` in the platform repo"
                  />
                  <.palette_row
                    id="agents-base"
                    label="AGENTS"
                    chips={source_chips(:agent, @agent_defs, :app)}
                    empty_hint="none — add `priv/orchestrator/agents/<name>/NNNN.md`"
                  />
                  <.palette_row
                    id="adws-base"
                    label="ADWS"
                    chips={source_chips(:adw, @adws, :app)}
                    empty_hint="none — add `adws/adw_*.py`"
                  />
                </div>

                <div :if={@palette_source_tab == :project} class="flex flex-col gap-2">
                  <.palette_row
                    id="slash-project"
                    label="SLASH"
                    chips={source_chips(:slash_command, @slash_commands, :working_dir)}
                    empty_hint="none — select a project, or add `.claude/commands/<name>.md` in its repo"
                  />
                  <.palette_row
                    id="agents-project"
                    label="AGENTS"
                    chips={source_chips(:agent, @agent_defs, :working_dir)}
                    empty_hint="none — add `.claude/agents/<name>.md` in the project repo"
                  />
                  <.palette_row
                    id="adws-project"
                    label="ADWS"
                    chips={source_chips(:adw, @adws, :working_dir)}
                    empty_hint="none — add `adws/adw_*.py` in the project repo"
                  />
                </div>
              </div>
            </div>

            <div class="mt-2">
              <.palette_row
                id="live"
                label="LIVE AGENTS"
                chips={live_agent_chips(@agents, @statuses)}
                empty_hint="no live agents — create one, then click to reference it"
              />
            </div>
          </div>
        </div>

        <%!-- ADW BUILDER MODE --%>
        <%!-- A real <form> is required: LiveView refuses phx-change on inputs that are
             not inside a form ("form events require the input to be inside a form"),
             which otherwise swallows every keystroke silently. phx-submit is a no-op so
             pressing Enter in the name field doesn't trigger a native page reload. --%>
        <form :if={@adw_builder?} phx-submit="adw_noop" class="flex flex-col gap-3">
          <%!-- Workflow name + local toggle + harness picker --%>
          <div class="flex items-center gap-2">
            <div class="flex flex-col gap-1">
              <label
                for="adw-combo-name"
                class="text-[0.625rem] font-semibold"
                style="color: var(--cns-text-2)"
              >
                WORKFLOW NAME
              </label>
              <input
                id="adw-combo-name"
                type="text"
                placeholder="Combo name"
                aria-label="Workflow name"
                value={@adw_name}
                phx-change="adw_set_name"
                name="name"
                class="cns-cmd-textarea"
                style="padding: 0.25rem 0.5rem; height: auto"
              />
            </div>
            <div class="flex items-center gap-1">
              <button
                type="button"
                phx-click="adw_set_flavor"
                phx-value-flavor="iso"
                class={["cns-chip", @adw_flavor == :iso && "cns-chip--active"]}
                title="Isolated worktree — GitHub issue required"
              >
                Iso
              </button>
              <button
                type="button"
                phx-click="adw_set_flavor"
                phx-value-flavor="local_iso"
                class={["cns-chip", @adw_flavor == :local_iso && "cns-chip--active"]}
                title="Isolated worktree — no GitHub issue"
              >
                Local iso
              </button>
              <button
                type="button"
                phx-click="adw_set_flavor"
                phx-value-flavor="direct"
                class={["cns-chip", @adw_flavor == :direct && "cns-chip--active"]}
                title="In-place (no worktree) — runs in the current checkout"
              >
                Direct
              </button>
            </div>
            <select
              :if={@harness_names != []}
              name="harness"
              phx-change="adw_set_harness"
              class="cns-cmd-textarea"
              style="padding: 0.25rem 0.5rem; height: auto"
              title="Agent harness for this ADW run"
            >
              <option value="" selected={@adw_harness == ""}>— harness —</option>
              <option :for={h <- @harness_names} value={h} selected={h == @adw_harness}>
                {h}
              </option>
            </select>
          </div>

          <%!-- Load ADW: grouped picker showing saved combos + discovered ADWs from
               platform and project roots. Option value encodes "combo:<name>" or "adw:<path>".
               The ✕ deletes the selected combo's sidecar (combos only). --%>
          <div :if={@adw_loadable != []} class="flex items-center gap-2">
            <label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
              LOAD
            </label>
            <select
              name="combo"
              phx-change="adw_load_combo"
              class="cns-cmd-textarea"
              style="padding: 0.25rem 0.5rem; height: auto"
            >
              <option value="" selected={@adw_selected_combo == ""}>— pick an ADW —</option>
              <optgroup
                :if={Enum.any?(@adw_loadable, &(&1.kind == :combo and &1.source == :platform))}
                label="Saved combos (platform)"
              >
                <option
                  :for={
                    entry <-
                      Enum.filter(@adw_loadable, &(&1.kind == :combo and &1.source == :platform))
                  }
                  value={"combo:#{entry.ref}"}
                  selected={"combo:#{entry.ref}" == @adw_selected_combo}
                >
                  {entry.name} ({entry.flavor})
                </option>
              </optgroup>
              <optgroup
                :if={Enum.any?(@adw_loadable, &(&1.kind == :combo and &1.source == :project))}
                label="Saved combos (project)"
              >
                <option
                  :for={
                    entry <-
                      Enum.filter(@adw_loadable, &(&1.kind == :combo and &1.source == :project))
                  }
                  value={"combo:#{entry.ref}"}
                  selected={"combo:#{entry.ref}" == @adw_selected_combo}
                >
                  {entry.name} ({entry.flavor})
                </option>
              </optgroup>
              <optgroup
                :if={Enum.any?(@adw_loadable, &(&1.kind == :adw and &1.source == :platform))}
                label="Platform ADWs"
              >
                <option
                  :for={
                    entry <- Enum.filter(@adw_loadable, &(&1.kind == :adw and &1.source == :platform))
                  }
                  value={"adw:#{entry.ref}"}
                  selected={"adw:#{entry.ref}" == @adw_selected_combo}
                >
                  {entry.name}
                </option>
              </optgroup>
              <optgroup
                :if={Enum.any?(@adw_loadable, &(&1.kind == :adw and &1.source == :project))}
                label="Project ADWs"
              >
                <option
                  :for={
                    entry <- Enum.filter(@adw_loadable, &(&1.kind == :adw and &1.source == :project))
                  }
                  value={"adw:#{entry.ref}"}
                  selected={"adw:#{entry.ref}" == @adw_selected_combo}
                >
                  {entry.name}
                </option>
              </optgroup>
            </select>
            <button
              :if={String.starts_with?(@adw_selected_combo, "combo:")}
              type="button"
              phx-click="adw_delete_combo"
              phx-value-combo={String.replace_leading(@adw_selected_combo, "combo:", "")}
              class="cns-chip"
              style="color: var(--cns-red, #f87171)"
              title="Delete the selected combo's sidecar"
            >
              ✕
            </button>
          </div>

          <%!-- Spec + Initial-prompt inputs: give the built ADW its task context so
               launched steps render real prompts (not the empty-prompt default). --%>
          <div class="flex flex-col gap-1">
            <label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
              SPEC (optional)
            </label>
            <textarea
              name="spec"
              phx-change="adw_set_spec"
              rows="2"
              placeholder="Optional pre-written spec the ADW should act on ({{spec}})."
              class="cns-cmd-textarea"
            >{@adw_spec}</textarea>
          </div>

          <div class="flex flex-col gap-1">
            <label class="text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
              INITIAL PROMPT
            </label>
            <textarea
              name="prompt"
              phx-change="adw_set_prompt"
              rows="2"
              placeholder="The feature/task description that drives /feature ({{input}})."
              class="cns-cmd-textarea"
            >{@adw_prompt}</textarea>
          </div>

          <%!-- Step palette --%>
          <div>
            <div class="mb-1 text-[0.625rem] font-semibold" style="color: var(--cns-text-2)">
              ADD STEP
            </div>
            <div class="flex flex-wrap gap-1">
              <button
                :for={step <- ~w(plan patch build test review document ship)}
                type="button"
                phx-click="adw_add_step"
                phx-value-step={step}
                class="cns-cmd-chip"
                title={"#{step} step → runs /#{adw_step_command(step)}"}
              >
                + {adw_step_command(step)}
              </button>
            </div>
          </div>

          <%!-- Step list --%>
          <div class="flex flex-col gap-1">
            <div
              :if={@adw_steps == []}
              class="text-[0.625rem]"
              style="color: var(--cns-text-3)"
            >
              No steps yet — click above to add steps in order.
            </div>

            <div :for={{step, idx} <- Enum.with_index(@adw_steps)} class="cns-adw-step-row">
              <div class="flex items-center gap-1">
                <span class="cns-adw-step-num">{idx + 1}</span>
                <span class="cns-adw-step-name" title={"#{step.name} step"}>
                  {adw_step_command(step.name)}
                </span>

                <button
                  type="button"
                  phx-click="adw_toggle_step"
                  phx-value-id={step.id}
                  class="cns-chip"
                  title="View default prompt"
                  style="font-size: 0.5rem; padding: 1px 4px"
                >
                  {if step.expanded, do: "▲", else: "▼"}
                </button>

                <div class="ml-auto flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="adw_move_step"
                    phx-value-id={step.id}
                    phx-value-dir="up"
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px"
                    disabled={idx == 0}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    phx-click="adw_move_step"
                    phx-value-id={step.id}
                    phx-value-dir="down"
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px"
                    disabled={idx == length(@adw_steps) - 1}
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    phx-click="adw_remove_step"
                    phx-value-id={step.id}
                    class="cns-chip"
                    style="font-size: 0.5rem; padding: 1px 4px; color: var(--cns-red, #f87171)"
                  >
                    ✕
                  </button>
                </div>
              </div>

              <div
                :if={step.expanded}
                class="mt-1 rounded p-2 text-[0.6rem]"
                style="background: var(--cns-surface-3); color: var(--cns-text-2)"
              >
                <textarea
                  name={"prompt-#{step.id}"}
                  phx-change="adw_set_step_prompt"
                  phx-value-id={step.id}
                  rows="3"
                  class="cns-cmd-textarea"
                  style="font-size: 0.65rem"
                  placeholder={adw_step_hint(step.name)}
                >{step[:prompt] || ""}</textarea>

                <%!-- Per-step model overrides: harness → provider → model (cascade) --%>
                <div class="mt-1 flex flex-wrap gap-2 items-center">
                  <div class="flex items-center gap-1">
                    <label class="text-[0.55rem] font-semibold" style="color: var(--cns-text-3)">
                      HARNESS
                    </label>
                    <select
                      name={"step-harness-#{step.id}"}
                      phx-change="adw_set_step_harness"
                      phx-value-id={step.id}
                      class="cns-cmd-textarea"
                      style="padding: 1px 4px; height: auto; font-size: 0.6rem"
                    >
                      <option value="" selected={step[:harness] in [nil, ""]}>inherit</option>
                      <option
                        :for={h <- @harness_names}
                        value={h}
                        selected={step[:harness] == h}
                      >
                        {h}
                      </option>
                    </select>
                  </div>

                  <div class="flex items-center gap-1">
                    <label class="text-[0.55rem] font-semibold" style="color: var(--cns-text-3)">
                      PROVIDER
                    </label>
                    <input
                      type="text"
                      name={"step-provider-#{step.id}"}
                      phx-change="adw_set_step_provider"
                      phx-value-id={step.id}
                      value={step[:provider] || ""}
                      class="cns-cmd-textarea"
                      style="padding: 1px 4px; height: auto; font-size: 0.6rem; width: 8rem"
                      placeholder="inherit"
                    />
                  </div>

                  <div class="flex items-center gap-1">
                    <label class="text-[0.55rem] font-semibold" style="color: var(--cns-text-3)">
                      MODEL
                    </label>
                    <input
                      type="text"
                      name={"step-model-#{step.id}"}
                      phx-change="adw_set_step_model"
                      phx-value-id={step.id}
                      value={step[:model] || ""}
                      class="cns-cmd-textarea"
                      style="padding: 1px 4px; height: auto; font-size: 0.6rem; width: 12rem"
                      placeholder="inherit"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Save + Launch buttons. "Save combo" persists the current build as a
               named JSON sidecar AND materializes a portable adws/adw_<name>_iso.py
               (or _local_iso.py) that surfaces in the ADWs palette. --%>
          <div class="flex items-center justify-end gap-2">
            <button
              type="button"
              phx-click="adw_save_combo"
              class="cns-chip"
              style="color: var(--cns-green, #4ade80)"
              disabled={@adw_steps == []}
              title="Save this build as a named combo + generate its ADW script"
            >
              ⭑ Save combo
            </button>
            <button
              type="button"
              phx-click="run_adw_builder"
              class="cns-chip"
              style="color: var(--cns-cyan)"
              disabled={@adw_steps == []}
            >
              ▶ Launch ADW
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :chips, :list, required: true, doc: "normalized %{token,label,source,description} maps"
  attr :empty_hint, :string, required: true

  @doc """
  One collapsible row of the file-driven prompt palette. The toggle reveals a chip
  per definition; each chip dispatches `rb:insert-token` (handled client-side by the
  CommandPaste hook on the textarea) to append its token at the caret — no server
  round-trip. An empty category renders an actionable hint instead.
  """
  @spec palette_row(map()) :: Phoenix.LiveView.Rendered.t()
  def palette_row(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        id={"palette-toggle-#{@id}"}
        phx-click={JS.toggle(to: "#palette-#{@id}")}
        class="cns-cmd-chip font-semibold"
        title={"Toggle #{@label} palette"}
      >
        {@label} ({length(@chips)})
      </button>
      <div id={"palette-#{@id}"} class="mt-1 flex flex-wrap gap-1" style="display:none">
        <button
          :for={chip <- @chips}
          type="button"
          class="cns-cmd-chip"
          phx-click={
            JS.dispatch("rb:insert-token", to: "#command-textarea", detail: %{token: chip.token})
          }
          title={chip.description || chip.token}
        >
          <span
            :if={chip[:status]}
            class={[
              "inline-block size-1.5 rounded-full align-middle",
              status_dot_class(chip[:status])
            ]}
            style="margin-right: 4px"
          />
          {chip.label}
          <span
            :if={chip.source == :working_dir}
            class="cns-chip"
            style="font-size: 0.5rem; padding: 0 3px; margin-left: 3px"
            title="from the selected working directory"
          >
            wd
          </span>
        </button>
        <span :if={@chips == []} style="color: var(--cns-text-3)">{@empty_hint}</span>
      </div>
    </div>
    """
  end

  # --- private helpers ------------------------------------------------------

  # Normalize a file-derived definition list into chip render maps. The token is the
  # exact text appended into the prompt: `/<name>` for slash commands, the bare name
  # for agents, and a valid `start_adw` invocation for ADWs.
  @spec palette_chips(:slash_command | :agent | :adw, [struct()]) :: [chip()]
  defp palette_chips(:slash_command, list) do
    Enum.map(list, fn cmd ->
      %{
        token: "/" <> cmd.name,
        label: "/" <> cmd.name,
        source: cmd.source,
        description: cmd.description
      }
    end)
  end

  defp palette_chips(:agent, list) do
    Enum.map(list, fn agent ->
      %{
        token: agent.name,
        label: agent.name,
        source: agent.source,
        description: agent.description
      }
    end)
  end

  defp palette_chips(:adw, list) do
    Enum.map(list, fn adw ->
      %{
        token: "start_adw workflow_type=" <> adw.name,
        label: adw.name,
        source: adw.source,
        description: adw.description
      }
    end)
  end

  # Build the three autocomplete item lists (slash commands, agents, adws) and return
  # them as a single list of maps with trigger, token, label, and description keys.
  @spec autocomplete_items([struct()], [struct()], [struct()]) :: [
          %{trigger: String.t(), token: String.t(), label: String.t(), description: String.t()}
        ]
  defp autocomplete_items(slash_commands, agent_defs, adws) do
    slash =
      Enum.map(slash_commands, fn cmd ->
        %{
          trigger: "/",
          token: "/" <> cmd.name,
          label: cmd.name,
          description: cmd.description || ""
        }
      end)

    agents =
      Enum.map(agent_defs, fn agent ->
        %{
          trigger: "@",
          token: agent.name,
          label: agent.name,
          description: agent.description || ""
        }
      end)

    adw_items =
      Enum.map(adws, fn adw ->
        %{
          trigger: "!",
          token: "start_adw workflow_type=" <> adw.name,
          label: adw.name,
          description: adw.description || ""
        }
      end)

    slash ++ agents ++ adw_items
  end

  # Serialize the three file-derived definition lists into a JSON array for the
  # CommandAutocomplete hook (issue-autocomplete). Each item carries trigger, token,
  # label, and description so the client can render a filtering dropdown.
  @spec autocomplete_json([struct()], [struct()], [struct()]) :: String.t()
  defp autocomplete_json(slash_commands, agent_defs, adws) do
    slash_commands
    |> autocomplete_items(agent_defs, adws)
    |> Jason.encode!()
  end

  # Chips for one category, filtered to a single provenance (`:app` for the BASE tab,
  # `:working_dir` for the PROJECT tab) so the two source tabs each render only their own
  # artifacts. Filtering BEFORE normalization keeps each entry's `source` authoritative.
  @spec source_chips(:slash_command | :agent | :adw, [struct()], :app | :working_dir) :: [chip()]
  defp source_chips(category, list, source) do
    list
    |> Enum.filter(&(&1.source == source))
    |> then(&palette_chips(category, &1))
  end

  # Total count of file-derived definitions (slash + agents + adws) carrying `source`, for the
  # `base (N)` / `project (N)` tab labels.
  @spec palette_source_count([struct()], [struct()], [struct()], :app | :working_dir) ::
          non_neg_integer()
  defp palette_source_count(slash, agents, adws, source) do
    Enum.reduce([slash, agents, adws], 0, fn list, acc ->
      acc + Enum.count(list, &(&1.source == source))
    end)
  end

  # Build chips for the live workers shown in the left rail. The token is the worker's
  # exact `name` — the string `Agents.get_by_name_for_orchestrator/2` (`Repo.get_by(name:)`)
  # matches — so a clicked chip lands a name the orchestrator resolves the first time.
  # Active workers (`:idle`/`:running`/`:holding`) are listed, idle-first then alphabetical,
  # and each chip carries its resolved status for the row's status dot. A `:holding` worker
  # (blocked pending external input) stays listed so it remains visible and resumable
  # (issue holding-status-for-blocked-agents).
  @spec live_agent_chips([Agent.t()], %{optional(Ecto.UUID.t()) => atom()}) :: [chip()]
  defp live_agent_chips(agents, statuses) do
    agents
    |> Enum.map(fn agent -> {agent, Map.get(statuses, agent.id, agent.status)} end)
    |> Enum.filter(fn {_agent, status} -> status in [:idle, :running, :holding] end)
    |> Enum.sort_by(fn {agent, status} -> {status != :idle, agent.name} end)
    |> Enum.map(fn {agent, status} ->
      %{
        token: agent.name,
        label: agent.name,
        source: :live,
        description: "#{status} · click to reference #{agent.name} in the prompt",
        status: status
      }
    end)
  end

  # The command / prompt-markdown a builder step actually invokes at run time (per
  # adws/adw_modules/workflow_ops.py). Chip + step-row labels show THIS — the md that
  # runs — so what the operator clicks names the real prompt. The canonical step id
  # (plan/build/…) stays the pipeline vocabulary the Python dispatch and adw_new.py
  # VALID_STEPS allowlist match on, so only the DISPLAY label changes here.
  @spec adw_step_command(String.t()) :: String.t()
  defp adw_step_command("plan"), do: "feature"
  defp adw_step_command("build"), do: "implement"
  defp adw_step_command("ship"), do: "commit + pr"
  defp adw_step_command(other), do: other

  @spec adw_step_hint(String.t()) :: String.t()
  defp adw_step_hint("plan"),
    do: "/feature <spec-file> — AI reads the spec and writes a detailed implementation plan."

  defp adw_step_hint("patch"),
    do: "/patch <spec-file> — plans and applies a targeted patch/hotfix."

  defp adw_step_hint("build"),
    do: "/implement <plan-file> — reads the plan and implements all tasks; leaves code green."

  defp adw_step_hint("test"),
    do: "/test <spec-file> — writes and runs tests to cover the plan's acceptance criteria."

  defp adw_step_hint("review"),
    do: "/review <spec-file> — reviews the git diff against the spec; passes or raises issues."

  defp adw_step_hint("document"),
    do: "/document — generates or updates documentation based on the implemented changes."

  defp adw_step_hint("ship"),
    do: "/commit (+ /pull_request on the GitHub flavor) — commits pending changes and opens a PR."

  defp adw_step_hint(other), do: "/#{other} — custom step."

  @spec upload_error_to_string(atom()) :: String.t()
  defp upload_error_to_string(:too_large), do: "File too large (max 10 MB)"
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(_), do: "Upload error"

  # Duplicated from Console.SharedComponents (private there; also used by its
  # agent_rail_compact): live-status dot color for a palette chip.
  @spec status_dot_class(atom()) :: String.t()
  defp status_dot_class(:running), do: "bg-blue-500"
  defp status_dot_class(:succeeded), do: "bg-emerald-500"
  defp status_dot_class(:failed), do: "bg-red-500"
  defp status_dot_class(:error), do: "bg-red-500"
  defp status_dot_class(:queued), do: "bg-amber-500"
  # Amber dot, clearly different from the emerald "succeeded" dot.
  defp status_dot_class(:holding), do: "bg-amber-500"
  defp status_dot_class(_status), do: "bg-gray-500"
end
