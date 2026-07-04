defmodule RepoBuilderWeb.ConsoleLive.LogsPanel do
  @moduledoc """
  Logs panel of the console (docs/audit-2026-07.md F3, Phase 3): the event-stream
  filter/clear toggles, row expand/detail/open-file actions, the reusable multi-select +
  EXPLAIN/HIDE bulk actions, and the Log Database manager event handlers extracted
  verbatim from `ConsoleLive`. `ConsoleLive` delegates the panel's events here;
  cross-panel helpers (`restream/1`, `backfill_events/1`, `seed_workflow_progress/1`,
  `seed_log_manager/1`, `selected_rows/2`, …) live in `ConsoleLive.Shared`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4, stream_insert: 3, stream_delete: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.{Explain, Logs, Orchestrators, Workflows}
  alias RepoBuilderWeb.ConsoleLive.Shared

  @categories [:response, :tool, :thinking, :hook]
  # Terminal workflow run statuses (WorkflowRun.status): clearable from the ADWS view.
  @finished_workflow_statuses [:succeeded, :failed, :cancelled]

  @events ~w(toggle_category toggle_agent_filter set_search toggle_regex toggle_project_scope
             toggle_auto_follow toggle_thinking toggle_system toggle_show_hidden release_hidden
             clear_filters clear_workflows toggle_event open_event close_event open_file
             toggle_select select_drag clear_selection open_log_manager select_log_filter
             log_page_next log_page_prev log_toggle_select log_select_drag clear_log_selection
             log_make_visible log_make_invisible log_purge_selected purge_all_logs
             explain_selected hide_selected close_explain)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  # --- filter handlers (re-stream from the bounded buffer; streams aren't filterable) ---

  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("toggle_category", %{"cat" => cat}, socket) do
    case to_category(cat) do
      nil ->
        {:noreply, socket}

      category ->
        active = toggle_member(socket.assigns.active_categories, category)
        {:noreply, socket |> assign(:active_categories, active) |> Shared.restream()}
    end
  end

  def handle_event("toggle_agent_filter", %{"id" => id}, socket) do
    active =
      if id in socket.assigns.active_agents,
        do: List.delete(socket.assigns.active_agents, id),
        else: [id | socket.assigns.active_agents]

    {:noreply, socket |> assign(:active_agents, active) |> Shared.restream()}
  end

  def handle_event("set_search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(:search, q) |> Shared.restream()}

  def handle_event("toggle_regex", _params, socket),
    do: {:noreply, socket |> assign(:regex?, not socket.assigns.regex?) |> Shared.restream()}

  # Flip the project scope (issue-scope-logs-to-active-project) and re-filter the buffer.
  # Scope off re-reveals other projects' buffered rows; on re-hides them (rows are never
  # dropped from `event_buffer`, so this is a pure view toggle).
  def handle_event("toggle_project_scope", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:project_scoped?, not socket.assigns.project_scoped?)
       |> Shared.restream()}

  def handle_event("toggle_auto_follow", _params, socket),
    do: {:noreply, assign(socket, :auto_follow?, not socket.assigns.auto_follow?)}

  def handle_event("toggle_thinking", _params, socket),
    do: {:noreply, assign(socket, :show_thinking?, not socket.assigns.show_thinking?)}

  # Flip the `@show_system?` toggle (issue filter-sys-logs) and re-filter the buffered
  # rows through the updated `passes?/2` chain so already-buffered `:system` rows become
  # visible (or hidden) without a DB round-trip. Mirror-symmetric with `toggle_project_scope`
  # above. The toggle is INDEPENDENT of the four `active_categories` toggles so CLEAR does
  # not flip it (a deliberate asymmetry — see `clear_filters/2` below).
  def handle_event("toggle_system", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:show_system?, not socket.assigns.show_system?)
       |> Shared.restream()}

  # Troubleshooting: reveal (or re-hide) rows soft-hidden by CLEAR. Flip the flag, then
  # re-seed the log stream + workflow swimlanes from the DB honoring the new flag.
  def handle_event("toggle_show_hidden", _params, socket) do
    socket = assign(socket, :show_hidden?, not socket.assigns.show_hidden?)
    {:noreply, socket |> Shared.backfill_events() |> Shared.seed_workflow_progress()}
  end

  # Durable reveal: permanently un-hide every row soft-hidden by CLEAR (the inverse of
  # CLEAR). Unlike the troubleshooting peek, this persists hidden=false so the rows stay
  # visible across reconnects without holding a flag on. Re-seed the streams from the
  # now-visible DB and flash a transient "Released N rows" confirmation.
  def handle_event("release_hidden", _params, socket) do
    released = Logs.release_hidden_logs() + Workflows.release_hidden_runs()
    Process.send_after(self(), :clear_release_notice, 2_000)

    {:noreply,
     socket
     |> assign(:release_notice, released)
     |> Shared.backfill_events()
     |> Shared.seed_workflow_progress()}
  end

  # Reset every filter AND clear the log view. Empties the in-memory event buffer + the
  # rendered stream (and collapses expanded rows) AND soft-hides the persisted rows, so
  # the cleared state survives a reconnect. Nothing is deleted — the settings "show
  # hidden" toggle reveals it again. When troubleshooting (show_hidden?), skip the
  # persist so CLEAR stays a view-only reset.
  def handle_event("clear_filters", _params, socket) do
    # Discard the hidden-row count: the persist is a side effect, not a return value.
    _ = unless socket.assigns.show_hidden?, do: Logs.hide_all_logs()

    {:noreply,
     socket
     |> assign(
       active_categories: MapSet.new(@categories),
       active_agents: [],
       search: "",
       regex?: false,
       # Return to the documented default scope-on; `project_agent_keys` is the roster
       # set (rebuilt by `load_agents`), not a filter, so it survives a CLEAR.
       project_scoped?: true,
       event_buffer: [],
       expanded_ids: MapSet.new(),
       selected_ids: MapSet.new(),
       log_count: 0
     )
     |> stream(:events, [], reset: true)}
  end

  # Clear finished (succeeded/failed/cancelled) workflows from the ADWS view, and trim the
  # non-running event rows that back the LOGS view + workflow step-squares. Soft-hides the
  # persisted data so the cleared state survives a reconnect. Running/queued work stays;
  # nothing is deleted (reversible via the settings "show hidden" toggle). When
  # troubleshooting (show_hidden?), skip the persist so CLEAR stays a view-only reset.
  def handle_event("clear_workflows", _params, socket) do
    # Existing: drop finished workflow cards and persist cleared state.
    _ = unless socket.assigns.show_hidden?, do: Workflows.hide_finished_runs()

    kept =
      socket.assigns.workflow_progress
      |> Enum.reject(fn {_run_id, view} -> view.status in @finished_workflow_statuses end)
      |> Map.new()

    # Derive the clearable agent_key set from event_buffer + statuses. Any key whose current
    # status is not :running (nor :holding — a held worker is blocked and resumable, not
    # finished) is clearable (issue holding-status-for-blocked-agents).
    clearable_keys =
      socket.assigns.event_buffer
      |> Enum.map(& &1.agent_key)
      |> Enum.uniq()
      |> Enum.reject(fn k ->
        Map.get(socket.assigns.statuses, k, :idle) in [:running, :holding]
      end)
      |> MapSet.new()

    # Trim event_buffer; the LOGS stream + workflow step-squares recompute from it.
    {cleared_rows, kept_buffer} =
      Enum.split_with(socket.assigns.event_buffer, fn row ->
        MapSet.member?(clearable_keys, row.agent_key)
      end)

    # Drop clearable keys from @statuses so running_count/1 badge stays accurate.
    kept_statuses =
      Map.reject(socket.assigns.statuses, fn {k, _} -> MapSet.member?(clearable_keys, k) end)

    # Durable: soft-hide worker swimlanes (UUID-shaped agent_key) in the DB so the clear
    # survives a reconnect (backfill_events reads list_recent_global which respects hidden).
    # Orchestrator-derived lanes ("orch-…" keys) are cleared view-only; persisting those
    # is governed by the orchestrator/chat backfill path and is out of scope here.
    _ =
      unless socket.assigns.show_hidden? do
        worker_keys =
          clearable_keys
          |> Enum.filter(fn k -> match?({:ok, _}, Ecto.UUID.cast(k)) end)

        Logs.hide_logs_for_agents(worker_keys)
      end

    socket =
      socket
      |> assign(:workflow_progress, kept)
      |> assign(:event_buffer, kept_buffer)
      |> assign(:statuses, kept_statuses)

    # stream_delete each cleared row from :events (mirrors hide_selected, lines 1728-1734).
    socket = Enum.reduce(cleared_rows, socket, &stream_delete(&2, :events, &1))

    {:noreply, socket}
  end

  def handle_event("toggle_event", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = toggle_member(socket.assigns.expanded_ids, id)
    socket = assign(socket, :expanded_ids, expanded)

    case Enum.find(socket.assigns.event_buffer, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, stream_insert(socket, :events, row)}
    end
  end

  def handle_event("open_event", %{"id" => id}, socket) do
    id = String.to_integer(id)

    {:noreply,
     assign(socket, :selected_event, Enum.find(socket.assigns.event_buffer, &(&1.id == id)))}
  end

  def handle_event("close_event", _params, socket),
    do: {:noreply, assign(socket, :selected_event, nil)}

  # Open a file in the operator's configured editor (issue file-diff-event-cards).
  # `RepoBuilder.Editor.open/1` validates the path and guards the editor command.
  def handle_event("open_file", %{"path" => path}, socket) do
    msg =
      case RepoBuilder.Editor.open(path) do
        {:ok, opened} ->
          {:info, "Opened #{Path.basename(opened)} in editor"}

        {:error, :disabled} ->
          {:error, "Editor integration is disabled"}

        {:error, :invalid_path} ->
          {:error, "Invalid file path"}

        {:error, :not_found} ->
          {:error, "File not found: #{Path.basename(path)}"}

        {:error, {:exit, code}} ->
          {:error, "Editor exited with code #{code}"}
      end

    case msg do
      {:info, text} -> {:noreply, put_flash(socket, :info, text)}
      {:error, text} -> {:noreply, put_flash(socket, :error, text)}
    end
  end

  # --- reusable event-stream selection + bulk actions (issue-explain) ---

  # Toggle one row's membership in the action-agnostic selection. Re-stream the row so
  # its checkbox reflects the new state (the stream only re-renders changed items).
  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = toggle_member(socket.assigns.selected_ids, id)
    socket = assign(socket, :selected_ids, selected)

    case Enum.find(socket.assigns.event_buffer, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, stream_insert(socket, :events, row)}
    end
  end

  # Range selection committed by the DragSelect JS hook (issue drag-select): ADD or
  # REMOVE the dragged ids (additive/subtractive over the existing selection, honoring
  # `mode`) in a SINGLE round-trip, then re-stream only the rows whose membership actually
  # changed so authoritative checkbox state reconciles the hook's optimistic paint.
  def handle_event("select_drag", %{"ids" => ids, "mode" => mode}, socket) do
    {:noreply, apply_drag_selection(socket, parse_ids(ids), normalize_mode(mode))}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, clear_selection(socket)}

  # --- Log Database manager (issue-log-db-manager) ---
  # A paginated, filterable DB browser over `agent_logs`. Its selection is a MapSet of
  # `id` UUID STRINGS, persisting across pages so a purge/visibility action can span them.

  # Re-query the manager's current filter/page when it opens (its assigns are seeded on
  # mount, but rows may have changed since; this keeps the first paint authoritative).
  def handle_event("open_log_manager", _params, socket),
    do: {:noreply, Shared.refresh_log_manager(socket)}

  # Switch the All/Visible/Hidden filter: reset to page 1, clear the selection (so stale,
  # off-page ids can't apply to a different filtered set), and re-query.
  def handle_event("select_log_filter", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(:log_mgr_filter, log_filter(filter))
      |> assign(:log_mgr_offset, 0)
      |> assign(:log_mgr_selected, MapSet.new())
      |> Shared.refresh_log_manager()

    {:noreply, socket}
  end

  def handle_event("log_page_next", _params, socket) do
    %{log_mgr_offset: offset, log_mgr_limit: limit} = socket.assigns

    socket =
      socket |> assign(:log_mgr_offset, offset + limit) |> Shared.refresh_log_manager()

    {:noreply, socket}
  end

  def handle_event("log_page_prev", _params, socket) do
    %{log_mgr_offset: offset, log_mgr_limit: limit} = socket.assigns

    socket =
      socket
      |> assign(:log_mgr_offset, max(offset - limit, 0))
      |> Shared.refresh_log_manager()

    {:noreply, socket}
  end

  def handle_event("log_toggle_select", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :log_mgr_selected, toggle_member(socket.assigns.log_mgr_selected, id))}
  end

  # Range selection committed by the LogDragSelect JS hook: union/difference the dragged
  # ids (UUID strings — no integer parse) into the manager selection in one round-trip.
  def handle_event("log_select_drag", %{"ids" => ids, "mode" => mode}, socket) do
    current = socket.assigns.log_mgr_selected
    delta = MapSet.new(Enum.filter(List.wrap(ids), &is_binary/1))

    next =
      case normalize_mode(mode) do
        :select -> MapSet.union(current, delta)
        :deselect -> MapSet.difference(current, delta)
      end

    {:noreply, assign(socket, :log_mgr_selected, next)}
  end

  def handle_event("clear_log_selection", _params, socket),
    do: {:noreply, assign(socket, :log_mgr_selected, MapSet.new())}

  def handle_event("log_make_visible", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.unhide_logs/1)}

  def handle_event("log_make_invisible", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.hide_logs/1)}

  def handle_event("log_purge_selected", _params, socket),
    do: {:noreply, mutate_log_selection(socket, &Logs.purge_logs/1)}

  # Guarded purge-EVERYTHING (also reachable from the Log Database settings tab). Resets
  # the manager to page 1, clears the selection, and re-queries (now empty).
  def handle_event("purge_all_logs", _params, socket) do
    _ = Logs.purge_all_logs()

    socket =
      socket
      |> assign(:log_mgr_offset, 0)
      |> assign(:log_mgr_selected, MapSet.new())
      |> Shared.refresh_log_manager()

    {:noreply, socket}
  end

  # EXPLAIN: gather the selected rows (order-preserving), resolve the Fast tier, and
  # start the ephemeral runner. The modal is shown client-side by the button's JS; this
  # only flips the assign to :running (or to an actionable error when no Fast agent).
  def handle_event("explain_selected", _params, socket) do
    rows = Shared.selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)

    if rows == [] do
      {:noreply, socket}
    else
      explain_selected(socket, rows)
    end
  end

  # HIDE: soft-hide the selected rows from the view (declutter), then clear the
  # selection. View-only — persisted history is untouched (reconnect re-backfills).
  def handle_event("hide_selected", _params, socket) do
    rows = Shared.selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)
    ids = MapSet.new(rows, & &1.id)
    buffer = Enum.reject(socket.assigns.event_buffer, &MapSet.member?(ids, &1.id))

    socket =
      socket
      |> assign(event_buffer: buffer, selected_ids: MapSet.new())

    socket = Enum.reduce(rows, socket, &stream_delete(&2, :events, &1))
    {:noreply, socket}
  end

  def handle_event("close_explain", _params, socket),
    do: {:noreply, assign(socket, :explain, %{status: :idle, request_id: nil, count: 0})}

  # --- private ---

  @spec to_category(String.t()) :: atom() | nil
  defp to_category("response"), do: :response
  defp to_category("tool"), do: :tool
  defp to_category("thinking"), do: :thinking
  defp to_category("hook"), do: :hook
  defp to_category(_other), do: nil

  # Inference-only spec — a `term()` member would be a supertype under :underspecs.
  defp toggle_member(set, member) do
    if MapSet.member?(set, member),
      do: MapSet.delete(set, member),
      else: MapSet.put(set, member)
  end

  # Reset the selection and re-stream the formerly-selected rows so their checkboxes
  # clear (the stream only re-renders items it is handed).
  @spec clear_selection(Socket.t()) :: Socket.t()
  defp clear_selection(socket) do
    rows = Shared.selected_rows(socket.assigns.event_buffer, socket.assigns.selected_ids)
    socket = assign(socket, :selected_ids, MapSet.new())
    Enum.reduce(rows, socket, &stream_insert(&2, :events, &1))
  end

  # Apply a drag-committed range to the selection and re-stream ONLY the rows whose
  # membership actually flipped (symmetric difference of old vs new), mirroring the
  # single-row `toggle_select` re-stream pattern.
  @spec apply_drag_selection(
          Socket.t(),
          [non_neg_integer()],
          :select | :deselect
        ) ::
          Socket.t()
  defp apply_drag_selection(socket, [], _mode), do: socket

  defp apply_drag_selection(socket, ids, mode) do
    current = socket.assigns.selected_ids
    delta = MapSet.new(ids)

    next =
      case mode do
        :select -> MapSet.union(current, delta)
        :deselect -> MapSet.difference(current, delta)
      end

    changed = MapSet.symmetric_difference(current, next)
    socket = assign(socket, :selected_ids, next)

    socket.assigns.event_buffer
    |> Enum.filter(&MapSet.member?(changed, &1.id))
    |> Enum.reduce(socket, &stream_insert(&2, :events, &1))
  end

  # Guarded parse of the drag payload's ids: keep only well-formed non-negative integers,
  # dropping any non-numeric/stale entries.
  @spec parse_ids(term()) :: [non_neg_integer()]
  defp parse_ids(ids) when is_list(ids), do: Enum.flat_map(ids, &parse_one_id/1)
  defp parse_ids(_ids), do: []

  @spec parse_one_id(term()) :: [non_neg_integer()]
  defp parse_one_id(id) when is_integer(id) and id >= 0, do: [id]

  defp parse_one_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n >= 0 -> [n]
      _ -> []
    end
  end

  defp parse_one_id(_id), do: []

  @spec normalize_mode(term()) :: :select | :deselect
  defp normalize_mode("deselect"), do: :deselect
  defp normalize_mode(_mode), do: :select

  # Apply a context mutation (`hide`/`unhide`/`purge`) to the manager's selected ids, then
  # clear the selection and re-query so the table, total, and pagination stay correct (the
  # offset clamps via `seed_log_manager/1` if the last page shrank below it).
  @spec mutate_log_selection(Socket.t(), ([Ecto.UUID.t()] -> non_neg_integer())) ::
          Socket.t()
  defp mutate_log_selection(socket, fun) do
    _ = fun.(MapSet.to_list(socket.assigns.log_mgr_selected))

    socket
    |> assign(:log_mgr_selected, MapSet.new())
    |> Shared.refresh_log_manager()
  end

  # Guarded string→atom for the manager's visibility filter (never `String.to_atom/1` on
  # input, AGENTS.md); an unknown value falls back to `:all`.
  @spec log_filter(term()) :: Logs.log_filter()
  defp log_filter("visible"), do: :visible
  defp log_filter("hidden"), do: :hidden
  defp log_filter(_filter), do: :all

  @spec explain_selected(Socket.t(), [map()]) :: {:noreply, Socket.t()}
  defp explain_selected(socket, rows) do
    count = length(rows)

    with id when is_binary(id) <- socket.assigns.orchestrator_id,
         {:ok, orchestrator} <- Orchestrators.fetch(id),
         {:ok, request_id} <- Explain.explain(orchestrator, rows) do
      {:noreply,
       assign(socket, :explain, %{status: :running, request_id: request_id, count: count})}
    else
      {:error, :no_fast_agent} ->
        {:noreply,
         assign(socket, :explain, %{
           status: {:error, Shared.no_fast_agent_message()},
           request_id: nil,
           count: count
         })}

      _ ->
        {:noreply,
         assign(socket, :explain, %{
           status: {:error, "Could not start the explanation — no orchestrator available."},
           request_id: nil,
           count: count
         })}
    end
  end
end
