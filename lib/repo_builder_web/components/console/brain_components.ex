defmodule RepoBuilderWeb.Console.BrainComponents do
  @moduledoc """
  Orchestrator-brain panel components: the goal-card collapse strip, the
  autonomy (self-healing) panel, the workstreams swimlane board, and the
  per-category agent-models modal.

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.Console.SharedComponents, only: [hide_agent_models: 0]

  # --- goal-card collapse toggle (bottom orchestrator drawer) ----------------

  attr :ledger, :map, default: nil, doc: "the Orchestrator.Ledgers.view/1 map, or nil"
  attr :workstreams, :list, default: [], doc: "the Workstreams.list_records/1 list, or []"

  @doc """
  The compact one-line summary shown in the goal-card handle bar WHILE COLLAPSED: the current
  `🎯 focus` when set, else the goal, else a workstream-count fallback — single-line truncated so a
  long goal can't blow out the handle height. Keeps "what is it working on" glanceable without
  expanding the drawer.
  """
  @spec goal_card_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def goal_card_summary(assigns) do
    assigns = assign(assigns, :summary, summary_text(assigns.ledger, assigns.workstreams))

    ~H"""
    <span
      id="goal-card-summary"
      class="truncate whitespace-nowrap"
      style="color: var(--cns-text-2)"
    >
      {@summary}
    </span>
    """
  end

  # The collapsed-strip text: focus > goal > workstream count > a neutral label. Total over a nil
  # ledger and an empty workstream list.
  @spec summary_text(map() | nil, [map()]) :: String.t()
  defp summary_text(%{focus: focus}, _workstreams) when is_binary(focus) and focus != "",
    do: "🎯 " <> focus

  defp summary_text(%{goal: goal}, _workstreams) when is_binary(goal) and goal != "",
    do: "Goal: " <> goal

  defp summary_text(_ledger, [_ | _] = workstreams),
    do: "#{length(workstreams)} workstream(s)"

  defp summary_text(_ledger, _workstreams), do: "Goal card"

  # --- autonomy panel (self-healing Phase 6) --------------------------------

  attr :ledger, :map, default: nil, doc: "the Orchestrator.Ledgers.view/1 map, or nil"
  attr :holding_reason, :string, default: nil, doc: "escalation banner reason, or nil"

  @doc """
  The autonomy panel (self-healing Phase 6): the active orchestrator's goal, definition-of-done,
  lifecycle status, stall gauge, and latest progress — plus a loud "Escalated — awaiting human"
  banner with a one-click resume when the leader has escalated. Renders nothing when there is no
  goal and no escalation (back-compatible).
  """
  @spec autonomy_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def autonomy_panel(assigns) do
    ~H"""
    <div
      :if={@ledger || @holding_reason}
      id="autonomy-panel"
      class="space-y-1 border-t px-3 py-2 text-[0.7rem]"
      style="border-color: var(--cns-border)"
    >
      <div
        :if={@holding_reason}
        id="escalation-banner"
        class="rounded px-2 py-1 font-semibold"
        style="background: #f6dede; color: #b23b3b"
      >
        ⚠ Escalated — awaiting human: {@holding_reason}
        <button
          type="button"
          id="resume-orchestrator"
          phx-click="resume_orchestrator"
          class="ml-2 underline"
        >
          Resume
        </button>
        <button
          type="button"
          id="clear-escalation"
          phx-click="clear_escalation"
          class="ml-2 underline opacity-70"
        >
          Clear
        </button>
      </div>
      <div :if={@ledger}>
        <div id="ledger-goal" class="font-semibold" style="color: var(--cns-text)">
          Goal: {@ledger.goal}
        </div>
        <div
          :if={@ledger.focus}
          id="orchestrator-focus"
          class="font-semibold"
          style="color: var(--cns-cyan)"
        >
          🎯 FOCUS: {@ledger.focus}
        </div>
        <div
          :if={is_nil(@ledger.focus) && @ledger.status == :active}
          id="orchestrator-focus-hint"
          style="color: var(--cns-text-2)"
        >
          🎯 no focus set
        </div>
        <div id="ledger-dod" style="color: var(--cns-text-2)">
          Done when: {@ledger.definition_of_done}
        </div>
        <div class="flex items-center gap-2">
          <span id="ledger-status" class="cns-chip">{to_string(@ledger.status)}</span>
          <span id="ledger-stall" class="cns-chip">stall {@ledger.stall_count}</span>
        </div>
        <div :if={@ledger.progress} id="ledger-progress" style="color: var(--cns-text-2)">
          Last: {@ledger.progress.summary || "(no summary)"}
        </div>
      </div>
    </div>
    """
  end

  # --- workstreams swimlane board (adws-phase-swimlane) ---------------------

  attr :orchestrator_id, :string, required: true
  attr :workstreams, :list, default: [], doc: "the Orchestrator.Workstreams.list_records/1 list"
  attr :context_tokens, :integer, default: 0, doc: "the brain's latest-turn context occupancy"

  @doc """
  Workstreams Kanban board for the ADWS view (adws-phase-swimlane): four columns
  (Spec → Implement → Test → Review), each holding the phase cards whose `current_stage`
  matches. Cards carry a status chip, spec_path indicator, ui/ux badge, and record-stage
  quick-action buttons (✓ passed / ✗ failed / ⊘ blocked). Renders nothing when there are
  no workstreams (back-compatible).
  """
  @spec workstreams_swimlane(map()) :: Phoenix.LiveView.Rendered.t()
  def workstreams_swimlane(assigns) do
    assigns = assign(assigns, :stage_columns, swimlane_columns(assigns.workstreams))

    ~H"""
    <div
      :if={@workstreams != []}
      id="workstreams-swimlane"
      class="border-t mt-2 pt-2 text-[0.7rem]"
      style="border-color: var(--cns-border)"
    >
      <div class="flex items-center justify-between px-1 mb-2">
        <span class="font-semibold" style="color: var(--cns-text)">Workstreams</span>
        <span id="workstreams-swimlane-context" class="cns-chip" title="brain context occupancy">
          ctx {@context_tokens}
        </span>
      </div>
      <div class="grid grid-cols-4 gap-2">
        <div
          :for={{stage, pairs} <- @stage_columns}
          id={"swimlane-#{stage}"}
          class="flex flex-col gap-1 rounded p-1 min-h-[4rem]"
          style="background: var(--cns-surface-2)"
        >
          <div
            class="text-center font-semibold mb-1 text-[0.625rem] uppercase"
            style="color: var(--cns-text-2)"
          >
            {stage |> to_string() |> String.capitalize()}
          </div>
          <div
            :for={{ws, phase} <- pairs}
            id={"phase-card-#{phase.id}"}
            class="rounded px-2 py-1 space-y-1"
            style="background: var(--cns-bg, #1a1a1a)"
            data-workstream-id={ws.id}
            data-phase-status={to_string(phase.status)}
          >
            <div class="flex items-center gap-1 flex-wrap">
              <span
                class="font-semibold truncate max-w-[8rem]"
                style="color: var(--cns-text)"
                title={phase.title}
              >
                {phase.title}
              </span>
              <span class="cns-chip" data-phase-status={to_string(phase.status)}>
                {to_string(phase.status)}
              </span>
            </div>
            <span
              :if={phase.kind == :ui_ux}
              class="cns-chip"
              data-phase-kind="ui_ux"
              style="background: #6d3fb2; color: #fff"
              title="iterative UI/UX polish phase"
            >
              {ui_ux_badge(phase)}
            </span>
            <div
              :if={phase.spec_path}
              class="truncate"
              style="color: var(--cns-text-2)"
              title={phase.spec_path}
            >
              📄 {phase.spec_path}
            </div>
            <div class="flex items-center gap-1 flex-wrap">
              <button
                :for={outcome <- ["passed", "failed", "blocked"]}
                type="button"
                id={"record-stage-#{phase.id}-#{outcome}"}
                phx-click="record_stage"
                phx-value-ref={ws.id}
                phx-value-stage={to_string(stage)}
                phx-value-outcome={outcome}
                class="cns-chip"
                style={outcome_button_style(outcome)}
                title={"Record #{stage} as #{outcome}"}
              >
                {outcome_glyph(outcome)}
              </button>
            </div>
          </div>
          <div
            :if={pairs == []}
            class="text-center py-2"
            style="color: var(--cns-text-2)"
          >
            —
          </div>
        </div>
      </div>
    </div>
    """
  end

  # All phases across all workstreams grouped into the four Kanban columns. Done phases
  # (current_stage: :done) are excluded — they have completed all stages.
  @spec swimlane_columns([map()]) :: [{atom(), [{map(), map()}]}]
  defp swimlane_columns(workstreams) do
    pairs =
      for ws <- workstreams,
          phase <- ws.phases,
          phase.current_stage in [:spec, :implement, :test, :review],
          do: {ws, phase}

    for stage <- [:spec, :implement, :test, :review] do
      {stage, Enum.filter(pairs, fn {_ws, phase} -> phase.current_stage == stage end)}
    end
  end

  @spec outcome_button_style(String.t()) :: String.t()
  defp outcome_button_style("passed"), do: "background: #2f7d4f; color: #fff"
  defp outcome_button_style("failed"), do: "background: #b23b3b; color: #fff"
  defp outcome_button_style("blocked"), do: "background: #8a6d1f; color: #fff"

  @spec outcome_glyph(String.t()) :: String.t()
  defp outcome_glyph("passed"), do: "✓"
  defp outcome_glyph("failed"), do: "✗"
  defp outcome_glyph("blocked"), do: "⊘"

  # The `:ui_ux` phase badge (iterative-ui-ux polish phase): surface + iteration N/cap so the
  # operator sees which surface is being polished and how close it is to the MVP cap.
  # Inference-only spec — the success typing narrows the return below a hand-written String.t().
  defp ui_ux_badge(%{surface: surface, iteration: iteration}) do
    label = if is_nil(surface), do: "ui/ux", else: to_string(surface)
    "#{label} #{iteration}/#{ui_iteration_cap()}"
  end

  # The active `:ui_ux` review→fix iteration cap for display (mirrors Workstreams' config knob).
  @spec ui_iteration_cap() :: pos_integer()
  defp ui_iteration_cap do
    case Application.get_env(:repo_builder, :orchestrator, [])[:ui_iteration_cap] do
      cap when is_integer(cap) and cap > 0 -> cap
      _invalid -> 3
    end
  end

  attr :rows, :list,
    default: [],
    doc: "per-category roster rows: %{category, harness, provider, model, *_options}"

  attr :saved, :boolean, default: false, doc: "transient 'Saved ✓' state"
  attr :configured_count, :integer, default: 0, doc: "count of categories with a non-blank model"
  attr :updated_at, :string, default: nil, doc: "ISO8601 UTC timestamp of last agent_models write"

  @doc """
  Modal to assign, per worker category (fast/main/heavy/leader), the
  harness/provider/model the orchestrator spawns into. Always rendered (shown/hidden
  client-side). A blank model = unassigned ⇒ the orchestrator can't spawn there.
  """
  @spec agent_models_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_models_modal(assigns) do
    ~H"""
    <div
      id="agent-models-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_agent_models()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 56rem">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">
            AGENT MODELS — what the orchestrator spawns workers into
          </span>
          <div class="flex items-center gap-2">
            <span
              :if={@saved}
              class="cns-chip"
              style="color: var(--cns-green, #4ade80)"
            >
              Saved ✓
            </span>
            <span class="text-[0.625rem]" style="color: var(--cns-text-2)">
              {@configured_count}/4 configured
            </span>
            <button type="button" phx-click={hide_agent_models()} class="cns-chip">Done</button>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <form
            :for={row <- @rows}
            id={"agent-model-#{row.category}"}
            phx-change="set_agent_model"
            class="flex items-center gap-2"
          >
            <input type="hidden" name="category" value={row.category} />
            <span class="w-16 text-xs font-semibold uppercase" style="color: var(--cns-text-1)">
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
              <option value="" selected={row.model in [nil, ""]}>no model (won't spawn)…</option>
              <option :for={m <- row.model_options} value={m} selected={row.model == m}>{m}</option>
            </select>

            <span
              :if={Map.get(row, :inherited?, false)}
              id={"agent-model-#{row.category}-inherited"}
              class="cns-chip text-[0.625rem]"
              style="color: var(--cns-text-2)"
              title="This tier inherits the global default (Settings → Default Models)"
            >
              inherited
            </span>

            <button
              :if={not Map.get(row, :inherited?, false) and row.model not in [nil, ""]}
              type="button"
              phx-click="clear_agent_model"
              phx-value-category={row.category}
              class="cns-chip text-[0.625rem]"
              title="Clear this project's override so the tier re-inherits the global default"
            >
              reset
            </button>
          </form>
        </div>

        <p class="mt-3 text-[0.625rem]" style="color: var(--cns-text-2)">
          This roster is per-project. A tier left blank inherits the global default
          (Settings → Default Models); "reset" clears a project override so it re-inherits.
        </p>
        <p :if={@updated_at} class="mt-1 text-[0.625rem]" style="color: var(--cns-text-2)">
          Last changed {format_relative_time(@updated_at)}
        </p>
      </div>
    </div>
    """
  end

  @spec format_relative_time(String.t()) :: String.t()
  defp format_relative_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      _ ->
        "unknown"
    end
  end
end
