defmodule RepoBuilderWeb.Console.CostComponents do
  @moduledoc """
  Cost & budget panel components: the per-project cost report panel, the spend
  summary / cost-rollup / price-catalog tables, and the budget guardrails
  (badge, banner, kill switch, modal, panel).

  Extracted verbatim from `RepoBuilderWeb.ConsoleComponents` (audit F3 task 3.2);
  that module remains the façade and delegates here.
  """
  use RepoBuilderWeb, :html

  import RepoBuilderWeb.Console.SharedComponents, only: [hide_budget: 0]
  import RepoBuilderWeb.DashboardComponents, only: [cost_badge: 1]

  attr :report, :any, required: true

  @doc """
  Per-project cost panel (issue per-project-cost-tracking): the active project's lifetime
  total, a session/today/week/month period strip, a by-model breakdown, and Clear/Restore
  controls. `@report` is `%{report: ProjectReport.t(), periods: map()}`. The lifetime total
  is the *display* total (cleared rows excluded); a "N cleared (restorable)" marker shows
  when soft-hidden rows exist.
  """
  @spec project_cost_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def project_cost_panel(assigns) do
    ~H"""
    <div
      id="project-cost-panel"
      class="flex flex-col gap-3 rounded border p-3"
      style="border-color: var(--cns-border)"
    >
      <div class="flex items-center justify-between">
        <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
          This project — lifetime
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="clear_project_costs"
            data-confirm="Clear this project's cost rows? They're hidden, not deleted (restorable)."
            class="cns-chip text-[0.625rem]"
          >
            Clear
          </button>
          <button
            :if={@report.report.hidden?}
            type="button"
            phx-click="restore_project_costs"
            class="cns-chip text-[0.625rem]"
          >
            Restore
          </button>
        </div>
      </div>

      <div class="flex items-baseline gap-2">
        <span id="project-cost-total" class="text-lg font-semibold" style="color: var(--cns-text-1)">
          {cost_str(@report.report.total_usd)}
        </span>
        <span :if={@report.report.estimated?} class="cns-chip text-[0.625rem]">incl. est.</span>
        <span
          :if={@report.report.hidden?}
          class="text-[0.625rem]"
          style="color: var(--cns-text-2)"
        >
          some rows cleared (restorable)
        </span>
      </div>

      <div class="flex flex-wrap gap-3 text-[0.6875rem]" style="color: var(--cns-text-2)">
        <span>session {cost_str(@report.periods.session)}</span>
        <span>today {cost_str(@report.periods.today)}</span>
        <span>week {cost_str(@report.periods.week)}</span>
        <span>month {cost_str(@report.periods.month)}</span>
      </div>

      <div
        :if={@report.report.by_model == []}
        class="text-[0.625rem]"
        style="color: var(--cns-text-2)"
      >
        No spend recorded for this project yet.
      </div>

      <table
        :if={@report.report.by_model != []}
        id="project-cost-by-model"
        class="w-full text-[0.6875rem]"
      >
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @report.report.by_model} style="border-top: 1px solid var(--cns-border)">
            <td class="py-1 pr-2">{cost_dim(r.key)}</td>
            <td class="py-1 pr-2 text-right"><.spend_cost row={r} /></td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :summary, :any, required: true

  @doc """
  Time-windowed spend summary (issue-cost-adw-periods): Today / This week / This month,
  each broken down by harness and by provider. This is the **accounting** view — it counts
  all activity regardless of visibility (cleared/hidden logs included), so it stays put when
  CLEAR is pressed. Estimates are marked `est.` exactly as in the all-time rollup.
  """
  @spec spend_summary_table(map()) :: Phoenix.LiveView.Rendered.t()
  def spend_summary_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Spend by period
      </div>
      <p class="text-[0.625rem]" style="color: var(--cns-text-2)">
        All activity in {@summary.timezone} — includes cleared logs (accounting view, not the
        console buffer).
      </p>
      <.spend_period id="spend-today" label="Today" tz={@summary.timezone} period={@summary.today} />
      <.spend_period
        id="spend-week"
        label="This week"
        tz={@summary.timezone}
        period={@summary.week}
      />
      <.spend_period
        id="spend-month"
        label="This month"
        tz={@summary.timezone}
        period={@summary.month}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :tz, :string, required: true
  attr :period, :any, required: true

  # One period block: a heading with its local start boundary, plus the by-harness and
  # by-provider sub-tables.
  @spec spend_period(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_period(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div class="text-[0.6875rem] font-semibold">
        {@label}
        <span class="font-normal" style="color: var(--cns-text-2)">
          · since {RepoBuilder.Timezones.format_datetime(@period.since, @tz)}
        </span>
      </div>
      <.spend_breakdown id={"#{@id}-harness"} title="By harness" rows={@period.by_harness} />
      <.spend_breakdown id={"#{@id}-provider"} title="By provider" rows={@period.by_provider} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true

  # One dimension breakdown table (harness or provider) for a single period.
  @spec spend_breakdown(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_breakdown(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] uppercase" style="color: var(--cns-text-2)">{@title}</div>
      <div :if={@rows == []} class="text-[0.625rem]" style="color: var(--cns-text-2)">
        No spend.
      </div>
      <table :if={@rows != []} id={@id} class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Name</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows} style="border-top: 1px solid var(--cns-border)">
            <td class="py-1 pr-2">{cost_dim(r.key)}</td>
            <td class="py-1 pr-2 text-right"><.spend_cost row={r} /></td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :row, :any, required: true

  # Cost cell for a spend row: the billed amount (hidden when a bucket is purely an
  # estimate) plus an `est.`-marked catalog estimate when any unpriced portion exists.
  @spec spend_cost(map()) :: Phoenix.LiveView.Rendered.t()
  defp spend_cost(assigns) do
    ~H"""
    <span>
      <.cost_badge :if={spend_show_actual?(@row)} cost={@row.actual_cost_usd} />
      <span
        :if={@row.estimated_cost_usd}
        class="cns-chip"
        title="estimated from the price catalog"
      >
        {cost_str(@row.estimated_cost_usd)} <span style="color: var(--cns-text-2)">est.</span>
      </span>
    </span>
    """
  end

  attr :rollups, :list, required: true

  @doc """
  Recent-spend rollup grouped by `(harness, provider, model)`, most-recent first.
  Unpriced dimensions that the catalog can price show an `est.`-labelled estimate
  rather than a billed amount (issue-cost-center).
  """
  @spec cost_rollup_table(map()) :: Phoenix.LiveView.Rendered.t()
  def cost_rollup_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Recent spend
      </div>
      <div
        :if={@rollups == []}
        class="text-[0.625rem]"
        style="color: var(--cns-text-2)"
      >
        No cost recorded yet.
      </div>
      <table :if={@rollups != []} id="cost-rollup-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Harness</th>
            <th class="py-1 pr-2 text-left font-medium">Provider</th>
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">Cost</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Events</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={r <- @rollups}
            id={cost_rollup_row_id(r)}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{r.harness}</td>
            <td class="py-1 pr-2">{cost_dim(r.provider)}</td>
            <td class="py-1 pr-2">{cost_dim(r.model)}</td>
            <td class="py-1 pr-2 text-right">
              <span :if={r.estimated?} class="cns-chip" title="estimated from the price catalog">
                {cost_str(r.estimated_cost_usd)} <span style="color: var(--cns-text-2)">est.</span>
              </span>
              <.cost_badge :if={not r.estimated?} cost={r.actual_cost_usd} />
            </td>
            <td class="py-1 pr-2 text-right">{r.input_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.output_tokens}</td>
            <td class="py-1 pr-2 text-right">{r.event_count}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :form, :any, required: true
  attr :editing_price_id, :any, default: nil

  @doc """
  Editable price catalog (issue-cost-center): a create/edit form plus the current rows
  with per-row Edit + (confirmed) Delete. When `:editing_price_id` is set the form is in
  edit mode — its identity key inputs are locked (readonly) so an edit can never repoint
  the `(harness, provider, model)` key. Operator edits persist to `model_prices` and
  override config rates.
  """
  @spec price_catalog_table(map()) :: Phoenix.LiveView.Rendered.t()
  def price_catalog_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
        Price catalog (USD / Mtok)
      </div>

      <.form
        :if={@form}
        id="price-form"
        for={@form}
        phx-submit="save_price"
        class="flex flex-wrap items-end gap-2"
      >
        <div
          class="w-full text-[0.625rem] font-semibold uppercase"
          style="color: var(--cns-text-2)"
        >
          <span :if={@editing_price_id}>Editing {@form[:harness].value}/{@form[:model].value}</span>
          <span :if={!@editing_price_id}>New price</span>
        </div>
        <.input :if={@editing_price_id} field={@form[:id]} type="hidden" />
        <.input
          field={@form[:harness]}
          label="Harness"
          class="cns-input w-24"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:provider]}
          label="Provider"
          class="cns-input w-24"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:model]}
          label="Model"
          class="cns-input w-40"
          readonly={@editing_price_id != nil}
        />
        <.input
          field={@form[:input_price_per_mtok]}
          label="Input"
          type="number"
          step="any"
          class="cns-input w-20"
        />
        <.input
          field={@form[:output_price_per_mtok]}
          label="Output"
          type="number"
          step="any"
          class="cns-input w-20"
        />
        <button id="price-form-submit" type="submit" class="cns-chip">Save</button>
        <button
          :if={@editing_price_id}
          id="price-cancel"
          type="button"
          phx-click="cancel_edit"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>

      <table id="price-catalog-table" class="w-full text-[0.6875rem]">
        <thead>
          <tr style="color: var(--cns-text-2)">
            <th class="py-1 pr-2 text-left font-medium">Harness</th>
            <th class="py-1 pr-2 text-left font-medium">Provider</th>
            <th class="py-1 pr-2 text-left font-medium">Model</th>
            <th class="py-1 pr-2 text-right font-medium">In</th>
            <th class="py-1 pr-2 text-right font-medium">Out</th>
            <th class="py-1 pr-2 text-right font-medium">Source</th>
            <th class="py-1"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @rows}
            id={"price-row-#{p.id}"}
            style="border-top: 1px solid var(--cns-border)"
          >
            <td class="py-1 pr-2">{p.harness}</td>
            <td class="py-1 pr-2">{cost_dim(p.provider)}</td>
            <td class="py-1 pr-2">{p.model}</td>
            <td class="py-1 pr-2 text-right">{price_str(p.input_price_per_mtok)}</td>
            <td class="py-1 pr-2 text-right">{price_str(p.output_price_per_mtok)}</td>
            <td class="py-1 pr-2 text-right">{p.source}</td>
            <td class="py-1 text-right">
              <button
                type="button"
                id={"price-edit-#{p.id}"}
                phx-click="edit_price"
                phx-value-id={p.id}
                class="cns-chip"
              >
                Edit
              </button>
              <button
                type="button"
                id={"price-delete-#{p.id}"}
                phx-click="delete_price"
                phx-value-id={p.id}
                data-confirm="Delete this price? Manual rates are not restored by re-seed."
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

  # --- budget guardrails (issue-budget-guardrails) ---

  attr :state, :map, required: true, doc: "Budget.Guard.snapshot/0 result"

  @doc "Compact spend/cap budget badge — color-coded by the worst breaker state."
  @spec budget_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_badge(assigns) do
    assigns = assign(assigns, :worst, budget_worst_state(assigns.state))

    ~H"""
    <span
      id="budget-badge"
      class="badge badge-outline"
      data-budget-state={to_string(@worst)}
      title="Budget guardrails"
    >
      <%= case @worst do %>
        <% :tripped -> %>
          ⛔ budget
        <% :warning -> %>
          ⚠ budget
        <% _ -> %>
          ✓ budget
      <% end %>
    </span>
    """
  end

  attr :state, :map, required: true

  @doc """
  Tripped/kill-switch banner — rendered only when the kill switch is engaged or a cap is
  tripped. Names the offending cap(s) and offers a per-cap reset affordance.
  """
  @spec budget_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_banner(assigns) do
    assigns = assign(assigns, :tripped, Enum.filter(assigns.state.caps, &(&1.state == :tripped)))

    ~H"""
    <div
      :if={@state.kill_switch? or @tripped != []}
      id="budget-banner"
      class="flex flex-col gap-1 border px-3 py-2 text-[0.75rem]"
      style="border-color: #b91c1c; background: rgba(185,28,28,0.12); color: #fca5a5"
    >
      <div :if={@state.kill_switch?} class="font-semibold">
        🛑 KILL SWITCH ENGAGED — all new spend is blocked and live sessions were interrupted.
      </div>
      <div :for={row <- @tripped} class="flex items-center justify-between gap-2">
        <span>
          ⛔ {budget_scope_label(row.cap)} budget tripped — spent {budget_cost(row.spent)} of {budget_cost(
            row.cap.limit_usd
          )} ({budget_action_label(row.cap.action)})
        </span>
        <button
          type="button"
          id={"budget-reset-#{row.cap.id}"}
          phx-click="reset_budget"
          phx-value-id={row.cap.id}
          class="cns-chip"
        >
          Reset
        </button>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  @doc "The manual global kill-switch button (engage / release)."
  @spec kill_switch(map()) :: Phoenix.LiveView.Rendered.t()
  def kill_switch(assigns) do
    ~H"""
    <button
      type="button"
      id="kill-switch"
      phx-click="toggle_kill_switch"
      data-engaged={to_string(@state.kill_switch?)}
      class="cns-chip"
      style={if @state.kill_switch?, do: "color: #fca5a5; border-color: #b91c1c", else: ""}
    >
      {if @state.kill_switch?, do: "Release kill switch", else: "🛑 Kill switch"}
    </button>
    """
  end

  attr :state, :map, required: true
  attr :caps, :list, required: true, doc: "merged DB+live rows for the editable list"
  attr :form, :any, required: true
  attr :scope, :string, default: "global", doc: "the form's currently-selected scope"

  attr :scope_targets, :map,
    default: %{},
    doc:
      ~S(`%{"orchestrator" => [{label, id}], "workflow" => [{label, id}]}` for the scope_id picker)

  attr :editing?, :boolean, default: false, doc: "true when the form is editing an existing cap"

  @doc """
  Budget guardrails as a popup modal (opened from the header `#stat-cost` pill). Shown
  and hidden client-side like the other console modals; wraps the existing live
  `budget_badge` + `budget_panel` so there is a single source of truth for the markup.
  """
  @spec budget_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_modal(assigns) do
    ~H"""
    <div
      id="budget-modal"
      class="cns-cmd-overlay"
      style="display:none"
      phx-window-keydown={hide_budget()}
      phx-key="Escape"
    >
      <div class="cns-cmd-panel" style="max-width: 40rem">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-xs font-semibold" style="color: var(--cns-cyan)">BUDGET</span>
          <div class="flex items-center gap-2">
            <.budget_badge state={@state} />
            <button type="button" phx-click={hide_budget()} class="cns-chip">Done</button>
          </div>
        </div>

        <.budget_panel
          state={@state}
          caps={@caps}
          form={@form}
          scope={@scope}
          scope_targets={@scope_targets}
          editing?={@editing?}
        />
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  attr :caps, :list,
    required: true,
    doc: ~S(merged rows `%{cap, spent, ratio, state}` — DB caps overlaid with live spend)

  attr :form, :any, required: true
  attr :scope, :string, default: "global"
  attr :scope_targets, :map, default: %{}
  attr :editing?, :boolean, default: false

  @doc """
  Budget panel: a single spend-vs-cap list where every cap carries its own
  Edit / Reset / Delete controls, plus a create-or-edit form. The rows are the union of the
  durable DB caps (authoritative — the editable source of truth) and the live
  `Budget.Guard` snapshot (live spend/state), keyed by cap id, so every cap the operator
  can SEE is one they can act on — there are no DB-only or memory-only "ghost" rows the UI
  can't reach. Caps CRUD goes through the `RepoBuilder.Budget` context (the web layer never
  touches `Repo`).
  """
  @spec budget_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_panel(assigns) do
    ~H"""
    <div id="budget-panel" class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-[0.625rem] font-semibold uppercase" style="color: var(--cns-text-2)">
          Budget guardrails
        </span>
        <.kill_switch state={@state} />
      </div>

      <div :if={@caps == []} class="text-[0.625rem]" style="color: var(--cns-text-2)">
        No budget caps yet — spend is unbounded. Add a cap below.
      </div>

      <div :for={row <- @caps} id={"budget-cap-#{row.cap.id}"} class="flex flex-col gap-0.5">
        <div class="flex items-center justify-between gap-2 text-[0.6875rem]">
          <span class="truncate">
            {budget_scope_label(row.cap)} · {row.cap.period} · {budget_action_label(row.cap.action)}
          </span>
          <div class="flex shrink-0 items-center gap-2">
            <span data-budget-state={to_string(row.state)}>
              {budget_cost(row.spent)} / {budget_cost(row.cap.limit_usd)}
            </span>
            <button
              type="button"
              id={"budget-edit-#{row.cap.id}"}
              phx-click="edit_budget"
              phx-value-id={row.cap.id}
              class="cns-chip"
            >
              Edit
            </button>
            <button
              :if={row.state == :tripped}
              type="button"
              id={"budget-panel-reset-#{row.cap.id}"}
              phx-click="reset_budget"
              phx-value-id={row.cap.id}
              class="cns-chip"
            >
              Reset
            </button>
            <button
              type="button"
              id={"budget-delete-#{row.cap.id}"}
              phx-click="delete_budget"
              phx-value-id={row.cap.id}
              data-confirm="Delete this budget cap?"
              class="cns-chip"
            >
              Delete
            </button>
          </div>
        </div>
        <div class="h-1.5 w-full overflow-hidden rounded" style="background: var(--cns-border)">
          <div
            class="h-full"
            style={"width: #{budget_pct(row.ratio)}%; background: #{budget_bar_color(row.state)}"}
          />
        </div>
      </div>

      <.form
        :if={@form}
        id="budget-form"
        for={@form}
        phx-change="budget_form_change"
        phx-submit="save_budget"
        class="flex flex-wrap items-end gap-2"
      >
        <.input
          field={@form[:scope]}
          label="Scope"
          type="select"
          options={[
            {"Global", "global"},
            {"Project", "project"},
            {"Orchestrator", "orchestrator"},
            {"Workflow", "workflow"}
          ]}
          class="cns-input w-28"
        />
        <%= if @scope != "global" do %>
          <.input
            :if={Map.get(@scope_targets, @scope, []) != []}
            field={@form[:scope_id]}
            label="Target"
            type="select"
            options={Map.get(@scope_targets, @scope, [])}
            class="cns-input w-44"
          />
          <.input
            :if={Map.get(@scope_targets, @scope, []) == []}
            field={@form[:scope_id]}
            label={"#{String.capitalize(@scope)} id"}
            class="cns-input w-44"
          />
        <% end %>
        <.input
          field={@form[:period]}
          label="Period"
          type="select"
          options={[
            {"Total", "total"},
            {"Session", "session"},
            {"Daily", "daily"},
            {"Monthly", "monthly"}
          ]}
          class="cns-input w-24"
        />
        <.input
          field={@form[:limit_usd]}
          label="Limit $"
          type="number"
          step="any"
          class="cns-input w-24"
        />
        <.input
          field={@form[:action]}
          label="When exceeded"
          type="select"
          options={[{"Warn me", "alert"}, {"Pause runs", "pause"}, {"Hard stop", "hard_stop"}]}
          class="cns-input w-32"
        />
        <button id="budget-form-submit" type="submit" class="cns-chip">
          {if @editing?, do: "Save cap", else: "Add cap"}
        </button>
        <button
          :if={@editing?}
          type="button"
          id="budget-form-cancel"
          phx-click="cancel_edit_budget"
          class="cns-chip"
        >
          Cancel
        </button>
      </.form>
    </div>
    """
  end

  @spec budget_worst_state(map()) :: :ok | :warning | :tripped
  defp budget_worst_state(%{kill_switch?: true}), do: :tripped

  defp budget_worst_state(%{caps: caps}) do
    states = Enum.map(caps, & &1.state)

    cond do
      :tripped in states -> :tripped
      :warning in states -> :warning
      true -> :ok
    end
  end

  @spec budget_scope_label(RepoBuilder.Budget.Cap.t()) :: String.t()
  defp budget_scope_label(%{scope: :global}), do: "Global"
  defp budget_scope_label(%{scope: scope, scope_id: id}), do: "#{scope}:#{id}"

  # Inference-only spec — the concrete action atoms narrow below `atom()`.
  defp budget_action_label(:alert), do: "alert"
  defp budget_action_label(:pause), do: "pause"
  defp budget_action_label(:hard_stop), do: "hard-stop"

  @spec budget_cost(Decimal.t() | nil) :: String.t()
  defp budget_cost(%Decimal{} = cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 2))
  defp budget_cost(_other), do: "—"

  @spec budget_pct(float()) :: integer()
  defp budget_pct(ratio) when is_float(ratio),
    do: ratio |> Kernel.*(100) |> min(100) |> max(0) |> round()

  defp budget_pct(_other), do: 0

  @spec budget_bar_color(atom()) :: String.t()
  defp budget_bar_color(:tripped), do: "#b91c1c"
  defp budget_bar_color(:warning), do: "#d97706"
  defp budget_bar_color(_ok), do: "#16a34a"

  # Stable DOM id for a rollup row (the dimension key; nil model/provider → "_").
  @spec cost_rollup_row_id(RepoBuilder.CostCenter.Rollup.t()) :: String.t()
  defp cost_rollup_row_id(rollup) do
    "cost-rollup-#{rollup.harness}-#{rollup.provider}-#{rollup.model || "_"}"
  end

  # A grouping dimension cell: blank provider/model → a muted "—".
  @spec cost_dim(String.t() | nil) :: String.t()
  defp cost_dim(value) when value in [nil, ""], do: "—"
  defp cost_dim(value) when is_binary(value), do: value

  @spec cost_str(Decimal.t() | nil) :: String.t()
  defp cost_str(%Decimal{} = cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 2))
  defp cost_str(nil), do: "—"

  # Show the billed badge when there is a real billed amount, or when nothing was
  # estimated (so a genuine `$0.00` still renders). A purely-estimated bucket (zero billed
  # + an estimate present) hides the `$0.00` badge and shows only the `est.` chip — mirrors
  # the all-time rollup's actual-vs-estimate display.
  @spec spend_show_actual?(RepoBuilder.CostCenter.SpendRow.t()) :: boolean()
  defp spend_show_actual?(%{estimated_cost_usd: nil}), do: true

  defp spend_show_actual?(%{actual_cost_usd: %Decimal{} = actual}),
    do: Decimal.compare(actual, 0) == :gt

  @spec price_str(Decimal.t() | nil) :: String.t()
  defp price_str(%Decimal{} = price), do: Decimal.to_string(price)
  defp price_str(nil), do: "—"
end
