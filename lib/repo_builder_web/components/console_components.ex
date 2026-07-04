defmodule RepoBuilderWeb.ConsoleComponents do
  @moduledoc """
  Typed function components for the multi-layered orchestration console
  (BUILD_PROMPT.md §9) — the header stat bar + glow view toggle, the rich agent
  rail (card + compact), the filter bar, the event row, the chat bubbles, and
  the global command-input modal — as `attr/3`-validated, harness-blind
  components.

  This module is a thin façade (audit F3 task 3.2): every component now lives
  in a per-panel `RepoBuilderWeb.Console.*Components` module mirroring the
  `ConsoleLive` panel split, and is `defdelegate`d here so all existing call
  sites (`import RepoBuilderWeb.ConsoleComponents` + `<.component .../>`) keep
  working unchanged. `attr`/`slot` declarations live at the definition site.
  """

  alias Phoenix.LiveView.JS
  alias RepoBuilderWeb.Console.AdwBuilderComponents
  alias RepoBuilderWeb.Console.BrainComponents
  alias RepoBuilderWeb.Console.ChatComponents
  alias RepoBuilderWeb.Console.CostComponents
  alias RepoBuilderWeb.Console.ExternalApisComponents
  alias RepoBuilderWeb.Console.LogsComponents
  alias RepoBuilderWeb.Console.SettingsComponents
  alias RepoBuilderWeb.Console.SharedComponents

  # --- shared (header, agent rail, orb, dir picker, modal JS toggles) --------

  defdelegate header_bar(assigns), to: SharedComponents
  defdelegate stat_pill(assigns), to: SharedComponents
  defdelegate agent_card(assigns), to: SharedComponents
  defdelegate agent_rail_compact(assigns), to: SharedComponents
  defdelegate activity_orb(assigns), to: SharedComponents
  defdelegate typing_indicator(assigns), to: SharedComponents
  defdelegate dir_picker_modal(assigns), to: SharedComponents
  defdelegate show_command(js \\ %JS{}), to: SharedComponents
  defdelegate hide_command(js \\ %JS{}), to: SharedComponents
  defdelegate show_agent_models(js \\ %JS{}), to: SharedComponents
  defdelegate hide_agent_models(js \\ %JS{}), to: SharedComponents
  defdelegate show_explain(js \\ %JS{}), to: SharedComponents
  defdelegate hide_explain(js \\ %JS{}), to: SharedComponents
  defdelegate show_settings(js \\ %JS{}), to: SharedComponents
  defdelegate hide_settings(js \\ %JS{}), to: SharedComponents
  defdelegate show_budget(js \\ %JS{}), to: SharedComponents
  defdelegate hide_budget(js \\ %JS{}), to: SharedComponents
  defdelegate show_log_manager(js \\ %JS{}), to: SharedComponents
  defdelegate hide_log_manager(js \\ %JS{}), to: SharedComponents

  # --- chat (orchestrator conversation + command panel) ----------------------

  defdelegate chat_message(assigns), to: ChatComponents
  defdelegate thinking_bubble(assigns), to: ChatComponents
  defdelegate streaming_bubble(assigns), to: ChatComponents
  defdelegate tool_use_card(assigns), to: ChatComponents
  defdelegate command_panel(assigns), to: ChatComponents
  defdelegate queued_messages(assigns), to: ChatComponents

  # --- brain (goal card, autonomy, workstreams, agent models) ----------------

  defdelegate goal_card_summary(assigns), to: BrainComponents
  defdelegate autonomy_panel(assigns), to: BrainComponents
  defdelegate workstreams_swimlane(assigns), to: BrainComponents
  defdelegate agent_models_modal(assigns), to: BrainComponents

  # --- logs (filter bar, event stream, log manager, explain) -----------------

  defdelegate filter_bar(assigns), to: LogsComponents
  defdelegate filter_chip(assigns), to: LogsComponents
  defdelegate event_row(assigns), to: LogsComponents
  defdelegate consumed_files(assigns), to: LogsComponents
  defdelegate file_change_card(assigns), to: LogsComponents
  defdelegate selection_bar(assigns), to: LogsComponents
  defdelegate log_manager_modal(assigns), to: LogsComponents
  defdelegate explain_modal(assigns), to: LogsComponents

  # --- settings ---------------------------------------------------------------

  defdelegate settings_modal(assigns), to: SettingsComponents
  defdelegate settings_tab_button(assigns), to: SettingsComponents
  defdelegate settings_field(assigns), to: SettingsComponents
  defdelegate stack_layers_table(assigns), to: SettingsComponents

  # --- external APIs ----------------------------------------------------------

  defdelegate external_apis_panel(assigns), to: ExternalApisComponents
  defdelegate smart_import_box(assigns), to: ExternalApisComponents
  defdelegate smart_import_status(assigns), to: ExternalApisComponents
  defdelegate api_row(assigns), to: ExternalApisComponents
  defdelegate api_errors(assigns), to: ExternalApisComponents

  # --- cost & budget ----------------------------------------------------------

  defdelegate project_cost_panel(assigns), to: CostComponents
  defdelegate spend_summary_table(assigns), to: CostComponents
  defdelegate cost_rollup_table(assigns), to: CostComponents
  defdelegate price_catalog_table(assigns), to: CostComponents
  defdelegate budget_badge(assigns), to: CostComponents
  defdelegate budget_banner(assigns), to: CostComponents
  defdelegate kill_switch(assigns), to: CostComponents
  defdelegate budget_modal(assigns), to: CostComponents
  defdelegate budget_panel(assigns), to: CostComponents

  # --- ⌘K command palette / ADW builder ---------------------------------------

  defdelegate global_command_input(assigns), to: AdwBuilderComponents
  defdelegate palette_row(assigns), to: AdwBuilderComponents
end
