defmodule RepoBuilder.Logs do
  @moduledoc """
  Context for canonical-event persistence and observability reads (BUILD_PROMPT.md
  §8). The only `Repo` caller for `agent_logs`/`system_logs`.

  `persist_event/2` redacts the event's `raw` (secrets never hit the DB, §4.1),
  maps the variant to an `event_type`, rolls usage into the embedded `Usage` value
  object (float→Decimal boundary), and inserts one `agent_logs` row.
  """
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 2, offset: 2]

  alias RepoBuilder.Harness.{Event, Redact}
  alias RepoBuilder.Logs.{AgentLog, SystemLog, Usage}
  alias RepoBuilder.Repo

  @typedoc "The four console agent-card counters, mirroring the live `@counters` shape."
  @type agent_counts :: %{
          responses: non_neg_integer(),
          tools: non_neg_integer(),
          hooks: non_neg_integer(),
          thinking: non_neg_integer()
        }

  @typedoc """
  Visibility filter for the Log Database manager (issue-log-db-manager): `:all` (no
  filter), `:visible` (`hidden == false`), `:hidden` (`hidden == true`).
  """
  @type log_filter :: :all | :visible | :hidden

  @empty_counts %{responses: 0, tools: 0, hooks: 0, thinking: 0}

  # Highest `:limit` a single `query_agent_logs/3` page may request (mirrors
  # `@max_system_log_limit` clamping); the manager's default page is 50 rows.
  @max_agent_log_limit 200

  @doc """
  Redact, map, and persist one canonical event as an `agent_logs` row.

  `attrs` must carry `:agent_id` (the FK) and `:session_id`. It MAY carry
  `:provider`/`:model` snapshots (issue-cost-center) for the dimensional rollup;
  missing keys degrade to `nil` columns (no crash).
  """
  @spec persist_event(Event.t(), map()) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  def persist_event(event, attrs) do
    scrubbed = Redact.scrub(event)

    params = %{
      agent_id: attrs[:agent_id],
      project_id: attrs[:project_id],
      session_id: attrs[:session_id],
      event_type: event_type(event),
      harness: to_string(event.harness),
      provider: attrs[:provider],
      model: attrs[:model],
      payload: event_payload(event, scrubbed.raw),
      usage: usage_params(event)
    }

    %AgentLog{}
    |> AgentLog.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Redact, map, and persist one orchestrator canonical event as an `agent_logs` row
  keyed by `orchestrator_id` (issue-d). Mirrors `persist_event/2` exactly — same
  redaction, same float→Decimal usage embed — but scopes the row to an orchestrator
  (no `agent_id`), giving observability parity with workers for both harnesses.

  `attrs` must carry `:orchestrator_id` and `:session_id`, and MAY carry
  `:provider`/`:model` snapshots (issue-cost-center) for the dimensional rollup;
  missing keys degrade to `nil` columns (no crash).
  """
  @spec persist_orchestrator_event(Event.t(), %{
          required(:orchestrator_id) => Ecto.UUID.t(),
          required(:session_id) => String.t(),
          optional(:provider) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:project_id) => Ecto.UUID.t() | nil
        }) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  def persist_orchestrator_event(event, attrs) do
    scrubbed = Redact.scrub(event)

    params = %{
      orchestrator_id: attrs[:orchestrator_id],
      project_id: attrs[:project_id],
      session_id: attrs[:session_id],
      event_type: event_type(event),
      harness: to_string(event.harness),
      provider: attrs[:provider],
      model: attrs[:model],
      payload: event_payload(event, scrubbed.raw),
      usage: usage_params(event)
    }

    %AgentLog{}
    |> AgentLog.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Durably record one OPERATOR chat turn — the human side of the orchestrator
  transcript (specs/issue-operator-persist-operator-chat-messages.md). Mirrors
  `persist_orchestrator_event/2`: an orchestrator-scoped `agent_logs` row with
  `event_type: :text_delta`, scoped by `:orchestrator_id` only (no `agent_id`).

  The row is distinguished from orchestrator REPLY text — which shares the same
  `orchestrator_id` — by the `payload["role"] == "operator"` marker, so the chat
  backfill (`list_recent_orchestrator_messages/2`, which already returns these rows
  unchanged) can render it as the operator's `:user` bubble instead of the
  orchestrator bubble. Without this row, operator prompts were purely ephemeral UI
  state and vanished on any LiveView reconnect/server restart.

  `attrs` must carry `:orchestrator_id`. `:session_id` is caller-supplied or a
  synthesized `"orch-<id>-op-<n>"`; `:harness` is the orchestrator's harness string
  (column parity, optional).
  """
  @spec persist_operator_message(String.t(), %{
          required(:orchestrator_id) => Ecto.UUID.t(),
          optional(:session_id) => String.t(),
          optional(:harness) => String.t() | nil
        }) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  def persist_operator_message(prompt, attrs) do
    orchestrator_id = attrs[:orchestrator_id]

    params = %{
      orchestrator_id: orchestrator_id,
      session_id: attrs[:session_id] || synth_operator_session(orchestrator_id),
      event_type: :text_delta,
      harness: attrs[:harness],
      payload: %{"text" => prompt, "role" => "operator", "thinking" => false}
    }

    %AgentLog{}
    |> AgentLog.changeset(params)
    |> Repo.insert()
  end

  @spec synth_operator_session(Ecto.UUID.t() | nil) :: String.t()
  defp synth_operator_session(orchestrator_id) do
    "orch-#{orchestrator_id}-op-#{System.unique_integer([:positive])}"
  end

  @doc """
  Format a persisted log's durable `log_no` as the human-readable `log-<n>` label
  surfaced in the event-detail drilldown. A `nil` (non-persisted live shard, or a row
  built before this field) degrades to `"—"`. Pure formatter — no `Repo` — co-located
  here so the live path, the backfill path, and tests share one definition.
  """
  @spec log_label(integer() | nil) :: String.t()
  def log_label(n) when is_integer(n), do: "log-#{n}"
  def log_label(_n), do: "—"

  @doc "The most recent `limit` agent_logs rows for an agent, in chronological order (reconnect backfill)."
  @spec list_recent(Ecto.UUID.t(), pos_integer()) :: [AgentLog.t()]
  def list_recent(agent_id, limit \\ 500) do
    AgentLog
    |> where([l], l.agent_id == ^agent_id)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The most recent `limit` agent_logs rows across ALL agents, in chronological
  order. Seeds the console's center stream + chat buffer on connect so a
  reconnect backfills instead of starting empty (§9 reconnect rule).

  Rows soft-hidden by the console CLEAR action are skipped unless `include_hidden?`
  is true (the settings "show hidden" troubleshooting toggle).
  """
  @spec list_recent_global(pos_integer(), boolean()) :: [AgentLog.t()]
  def list_recent_global(limit \\ 500, include_hidden? \\ false) do
    AgentLog
    |> filter_hidden(include_hidden?)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The most recent `limit` ORCHESTRATOR `:text_delta` rows (the finalized assistant
  text that becomes chat), in chronological order. The chat-pane reconnect/restart
  backfill source (issue-chat-history-backfill).

  Distinct from `list_recent_global/2`: the chat pane must NOT be rebuilt from the
  worker-dominated global stream slice. Workers emit far more events than the
  orchestrator, so once ≥`limit` worker rows accumulate after the last orchestrator
  message, the orchestrator's sparse chat rows fall out of the global most-recent
  window and the chat pane backfills empty — even though the rows are durably stored.
  Scoping to `not is_nil(orchestrator_id) and event_type == :text_delta` guarantees the
  chat history survives a restart independent of worker volume.

  Rows soft-hidden by the console CLEAR action are skipped unless `include_hidden?`
  is true (mirrors `list_recent_global/2`).
  """
  @spec list_recent_orchestrator_messages(pos_integer(), boolean()) :: [AgentLog.t()]
  def list_recent_orchestrator_messages(limit \\ 100, include_hidden? \\ false) do
    AgentLog
    |> where([l], not is_nil(l.orchestrator_id) and l.event_type == :text_delta)
    |> filter_hidden(include_hidden?)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The most recent `limit` `:text_delta` chat rows for ONE orchestrator, in
  chronological order — the per-orchestrator conversation backfill source
  (issue-conversation-history-scope). Identical shape/ordering to
  `list_recent_orchestrator_messages/2` (the unscoped global view kept for back-compat)
  but adds `where l.orchestrator_id == ^orchestrator_id`, so switching projects reloads
  exactly the active orchestrator's own conversation rather than a global slice that
  bleeds other projects' chat.

  Rows soft-hidden by the console CLEAR action are skipped unless `include_hidden?`
  is true (parity with the global query and the "show hidden" toggle).
  """
  @spec list_orchestrator_messages(Ecto.UUID.t(), pos_integer(), boolean()) :: [AgentLog.t()]
  def list_orchestrator_messages(orchestrator_id, limit \\ 100, include_hidden? \\ false) do
    AgentLog
    |> where([l], l.orchestrator_id == ^orchestrator_id and l.event_type == :text_delta)
    |> filter_hidden(include_hidden?)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Soft-hide EVERY currently-visible agent_logs row (the console "CLEAR" log action).
  Persists the cleared state so a reconnect stays empty; rows are NOT deleted and are
  revealed again by the settings "show hidden" toggle. Returns the count hidden.
  """
  @spec hide_all_logs() :: non_neg_integer()
  def hide_all_logs do
    {count, _} =
      AgentLog
      |> where([l], l.hidden == false)
      |> Repo.update_all(set: [hidden: true])

    count
  end

  @doc """
  Release (permanently un-hide) EVERY soft-hidden agent_logs row — the inverse of
  `hide_all_logs/0` and the console "Release hidden logs & workflows" action. Rows that
  were cleared return to the default view for good (the durable reveal, not the
  troubleshooting peek); already-visible rows are untouched. Returns the count released.
  """
  @spec release_hidden_logs() :: non_neg_integer()
  def release_hidden_logs do
    {count, _} =
      AgentLog
      |> where([l], l.hidden == true)
      |> Repo.update_all(set: [hidden: false])

    count
  end

  @doc """
  The persisted `agent_logs` rows for a concrete set of durable `log_no` numbers
  (issue orchestrator-log-lookup-tools), ordered ascending by `log_no`. Drives the
  orchestrator's `get_logs` tool: resolve a `log-<n>` reference (single / inclusive
  range / explicit array) back to its critical content.

  Numbers with no matching row are simply absent from the result (the caller reports
  them as "missing", never an error). Soft-hidden (console CLEAR) rows are excluded
  unless `:include_hidden?` is true. An empty list short-circuits to `[]` — no query.
  """
  @spec logs_by_numbers([integer()], keyword()) :: [AgentLog.t()]
  def logs_by_numbers(numbers, opts \\ [])

  def logs_by_numbers([], _opts), do: []

  def logs_by_numbers(numbers, opts) when is_list(numbers) do
    include_hidden? = Keyword.get(opts, :include_hidden?, false)

    AgentLog
    |> where([l], l.log_no in ^numbers)
    |> filter_hidden(include_hidden?)
    |> order_by([l], asc: l.log_no)
    |> Repo.all()
  end

  @spec filter_hidden(Ecto.Queryable.t(), boolean()) :: Ecto.Query.t()
  defp filter_hidden(query, true), do: where(query, [l], true)
  defp filter_hidden(query, false), do: where(query, [l], l.hidden == false)

  @doc """
  Filter-aware, paginated read of `agent_logs`, newest-first (issue-log-db-manager).
  Drives the Log Database manager's paginated table. `limit` clamps to
  #{@max_agent_log_limit} (default 50 when non-positive); `offset` clamps to `>= 0`.
  """
  @spec query_agent_logs(log_filter(), pos_integer(), non_neg_integer()) :: [AgentLog.t()]
  def query_agent_logs(filter \\ :all, limit \\ 50, offset \\ 0) do
    AgentLog
    |> apply_filter(filter)
    |> order_by([l], desc: l.log_no, desc: l.inserted_at)
    |> limit(^clamp_agent_limit(limit))
    |> offset(^clamp_offset(offset))
    |> Repo.all()
  end

  @doc """
  Total `agent_logs` row count for a visibility filter (issue-log-db-manager). Feeds the
  manager's "rows X–Y of N" label and Prev/Next bounds.
  """
  @spec count_agent_logs(log_filter()) :: non_neg_integer()
  def count_agent_logs(filter \\ :all) do
    AgentLog
    |> apply_filter(filter)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Soft-hide a specific set of `agent_logs` rows by id (issue-log-db-manager per-row
  visibility). Mirrors `hide_all_logs/0` but scoped to `ids`. An empty list is a no-op
  returning 0. Returns the count updated.
  """
  @spec hide_logs([Ecto.UUID.t()]) :: non_neg_integer()
  def hide_logs([]), do: 0

  def hide_logs(ids) when is_list(ids) do
    {count, _} =
      AgentLog
      |> where([l], l.id in ^ids)
      |> Repo.update_all(set: [hidden: true])

    count
  end

  @doc """
  Soft-hide all `agent_logs` rows belonging to the given agent UUIDs (the console
  ADWS "CLEAR" swimlane action). Mirrors `hide_logs/1` but scoped to the `agent_id`
  FK column rather than log row `id`. An empty list is a no-op returning 0.
  Returns the count updated.
  """
  @spec hide_logs_for_agents([Ecto.UUID.t()]) :: non_neg_integer()
  def hide_logs_for_agents([]), do: 0

  def hide_logs_for_agents(agent_ids) when is_list(agent_ids) do
    {count, _} =
      AgentLog
      |> where([l], l.agent_id in ^agent_ids)
      |> Repo.update_all(set: [hidden: true])

    count
  end

  @doc """
  Soft-hide every visible `agent_logs` row stamped with `project_id` — the per-project
  "Clear project costs" action (issue per-project-cost-tracking). Mirrors
  `hide_logs_for_agents/1` but scoped to the `project_id` column, so it never touches
  another project's (or unscoped) rows. Rows are kept (recoverable via
  `release_hidden_logs_for_project/1`). Returns the count hidden.
  """
  @spec hide_logs_for_project(Ecto.UUID.t()) :: non_neg_integer()
  def hide_logs_for_project(project_id) do
    {count, _} =
      AgentLog
      |> where([l], l.project_id == ^project_id and l.hidden == false)
      |> Repo.update_all(set: [hidden: true])

    count
  end

  @doc """
  Release (un-hide) every soft-hidden `agent_logs` row for `project_id` — the inverse of
  `hide_logs_for_project/1` ("Restore"). Scoped to the project, so it never reveals
  another project's cleared rows. Returns the count released.
  """
  @spec release_hidden_logs_for_project(Ecto.UUID.t()) :: non_neg_integer()
  def release_hidden_logs_for_project(project_id) do
    {count, _} =
      AgentLog
      |> where([l], l.project_id == ^project_id and l.hidden == true)
      |> Repo.update_all(set: [hidden: false])

    count
  end

  @doc """
  Un-hide (reveal) a specific set of `agent_logs` rows by id — the per-row inverse of
  `hide_logs/1` (issue-log-db-manager). An empty list is a no-op returning 0. Returns the
  count updated.
  """
  @spec unhide_logs([Ecto.UUID.t()]) :: non_neg_integer()
  def unhide_logs([]), do: 0

  def unhide_logs(ids) when is_list(ids) do
    {count, _} =
      AgentLog
      |> where([l], l.id in ^ids)
      |> Repo.update_all(set: [hidden: false])

    count
  end

  @doc """
  Hard-DELETE a specific set of `agent_logs` rows by id (issue-log-db-manager purge).
  Permanent — also removes the rows' contribution to Cost Center rollups. An empty list
  is a no-op returning 0. Returns the count deleted.
  """
  @spec purge_logs([Ecto.UUID.t()]) :: non_neg_integer()
  def purge_logs([]), do: 0

  def purge_logs(ids) when is_list(ids) do
    {count, _} =
      from(l in AgentLog, where: l.id in ^ids)
      |> Repo.delete_all()

    count
  end

  @doc """
  Hard-DELETE EVERY `agent_logs` row (issue-log-db-manager guarded purge-all). Permanent
  and total — empties the log store and clears all Cost Center history derived from it.
  Returns the count deleted.
  """
  @spec purge_all_logs() :: non_neg_integer()
  def purge_all_logs do
    {count, _} = Repo.delete_all(AgentLog)
    count
  end

  # Visibility filter for the manager queries, mirroring `filter_hidden/2`.
  @spec apply_filter(Ecto.Queryable.t(), log_filter()) :: Ecto.Query.t()
  defp apply_filter(query, :visible), do: where(query, [l], l.hidden == false)
  defp apply_filter(query, :hidden), do: where(query, [l], l.hidden == true)
  defp apply_filter(query, _all), do: where(query, [l], true)

  @spec clamp_agent_limit(integer()) :: pos_integer()
  defp clamp_agent_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_agent_log_limit)

  defp clamp_agent_limit(_limit), do: 50

  @spec clamp_offset(integer()) :: non_neg_integer()
  defp clamp_offset(offset) when is_integer(offset) and offset > 0, do: offset
  defp clamp_offset(_offset), do: 0

  @doc "Sum of all priced `cost_usd` across an agent's logs (unpriced rows contribute nothing)."
  @spec cost_rollup!(Ecto.UUID.t()) :: Decimal.t()
  def cost_rollup!(agent_id) do
    AgentLog
    |> where([l], l.agent_id == ^agent_id)
    |> Repo.all()
    |> Enum.reduce(Decimal.new(0), fn log, acc -> add_cost(acc, log.usage) end)
  end

  @doc """
  Sum of all priced `cost_usd` across an orchestrator's logs (issue-d). Unpriced
  rows (NULL cost) contribute nothing, preserving the nil-vs-0.0 distinction.
  """
  @spec orchestrator_cost_rollup!(Ecto.UUID.t()) :: Decimal.t()
  def orchestrator_cost_rollup!(orchestrator_id) do
    AgentLog
    |> where([l], l.orchestrator_id == ^orchestrator_id)
    |> Repo.all()
    |> Enum.reduce(Decimal.new(0), fn log, acc -> add_cost(acc, log.usage) end)
  end

  @doc """
  Context-window occupancy of a persisted `usage` embed: the prompt side only —
  `input_tokens + cache_read + cache_creation` (nil-safe). `output_tokens` is the
  generated reply, not prompt occupancy, so it is excluded (the next turn's usage
  already reflects it). The single source of truth shared by the live console path.
  """
  @spec context_size(Usage.t() | nil) :: non_neg_integer()
  def context_size(%Usage{} = usage) do
    nz(usage.input_tokens) + nz(usage.cache_read) + nz(usage.cache_creation)
  end

  def context_size(_usage), do: 0

  # Nil-safe non-negative-integer coalesce (a token field may be nil/absent). The
  # guard narrows the return to `non_neg_integer()` so the sum stays integral.
  @spec nz(integer() | nil) :: non_neg_integer()
  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_n), do: 0

  @doc """
  Per-agent latest context-window size (issue-per-agent token/context): for each
  agent the `context_size/1` of its most-recent `usage` row. Seeds the console agent
  card's CONTEXT WINDOW bar on mount/reconnect so it reflects persisted activity
  rather than only events observed live. Agents with no `usage` row are absent.
  """
  @spec context_tokens_by_agent() :: %{Ecto.UUID.t() => non_neg_integer()}
  def context_tokens_by_agent do
    AgentLog
    |> where([l], l.event_type == :usage and not is_nil(l.agent_id))
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> Repo.all()
    # Ascending order ⇒ each put overwrites the prior, leaving the latest row per agent.
    |> Enum.reduce(%{}, fn log, acc -> Map.put(acc, log.agent_id, context_size(log.usage)) end)
  end

  @doc """
  Latest context-window size for an orchestrator's OWN turns (issue orchestrator
  context bar): `context_size/1` of the most-recent `usage` row scoped to this
  orchestrator with no `agent_id` (orchestrator-own rows carry `orchestrator_id` and
  a nil `agent_id`; its workers' rows carry both, so the nil filter excludes them).
  Seeds the command-panel CONTEXT WINDOW bar on mount/reconnect. Returns 0 when the
  orchestrator has logged no own usage yet.
  """
  @spec orchestrator_context_tokens(Ecto.UUID.t()) :: non_neg_integer()
  def orchestrator_context_tokens(orchestrator_id) do
    AgentLog
    |> where(
      [l],
      l.event_type == :usage and l.orchestrator_id == ^orchestrator_id and is_nil(l.agent_id)
    )
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> 0
      log -> context_size(log.usage)
    end
  end

  @doc """
  Per-agent event counts mapped to the console's four card counters
  (`responses`/`tools`/`hooks`/`thinking`), mirroring the live
  `record_event`→`bump_counter` category derivation so seeded values agree with
  subsequent live increments:

    * `responses` — finalized non-thinking `text_delta` rows (partials are never persisted)
    * `thinking`  — finalized `text_delta` rows with the `thinking` payload flag
    * `tools`     — `tool_call` + `tool_result` rows (both are live category `:tool`)
    * `hooks`     — `status` rows

  Seeds the card counters on mount/reconnect. Agents with no counted rows are absent.
  """
  @spec event_counts_by_agent() :: %{Ecto.UUID.t() => agent_counts()}
  def event_counts_by_agent do
    AgentLog
    |> where(
      [l],
      not is_nil(l.agent_id) and
        l.event_type in [:text_delta, :tool_call, :tool_result, :status]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn log, acc ->
      case counter_key(log) do
        nil ->
          acc

        key ->
          counts = Map.get(acc, log.agent_id, @empty_counts)
          Map.put(acc, log.agent_id, Map.update!(counts, key, &(&1 + 1)))
      end
    end)
  end

  @system_logs_topic "system_logs"

  @doc "Subscribe to live system-log inserts (SystemLogsLive)."
  @spec subscribe_system_logs() :: :ok
  def subscribe_system_logs do
    _ = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, @system_logs_topic)
    :ok
  end

  @spec create_system_log(map()) :: {:ok, SystemLog.t()} | {:error, Ecto.Changeset.t()}
  def create_system_log(params) do
    case %SystemLog{} |> SystemLog.changeset(params) |> Repo.insert() do
      {:ok, log} = ok ->
        _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @system_logs_topic, {:system_log, log})
        ok

      error ->
        error
    end
  end

  @spec list_system_logs(pos_integer()) :: [SystemLog.t()]
  def list_system_logs(limit \\ 200) do
    Repo.all(from(l in SystemLog, order_by: [desc: l.inserted_at], limit: ^limit))
  end

  # Highest `:limit` a single `query_system_logs/1` page may request.
  @max_system_log_limit 200

  # The ONLY accepted `:level` values, mapped from wire strings to the enum atoms.
  # An unknown/blank level is ignored (no filter) — never `String.to_atom/1` on
  # input (AGENTS.md).
  @system_log_levels %{"debug" => :debug, "info" => :info, "warn" => :warn, "error" => :error}

  @doc """
  Filtered, paginated read of `system_logs`, newest-first. Drives the
  orchestrator's `read_system_logs` tool.

  Options:
    * `:limit` — page size (default 50, clamped to #{@max_system_log_limit})
    * `:offset` — rows to skip (default 0)
    * `:level` — one of `"debug"`/`"info"`/`"warn"`/`"error"`; anything else is ignored
    * `:message_contains` — case-insensitive substring match on `message`
  """
  @spec query_system_logs(keyword()) :: [SystemLog.t()]
  def query_system_logs(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    SystemLog
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> maybe_level(Keyword.get(opts, :level))
    |> maybe_contains(Keyword.get(opts, :message_contains))
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # --- private ---

  @spec clamp_limit(integer()) :: pos_integer()
  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_system_log_limit)

  defp clamp_limit(_limit), do: 50

  @spec maybe_level(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Queryable.t()
  defp maybe_level(query, level) when is_binary(level) do
    case Map.fetch(@system_log_levels, level) do
      {:ok, atom} -> where(query, [l], l.level == ^atom)
      :error -> query
    end
  end

  defp maybe_level(query, _level), do: query

  @spec maybe_contains(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Queryable.t()
  defp maybe_contains(query, term) when is_binary(term) and term != "" do
    where(query, [l], ilike(l.message, ^"%#{term}%"))
  end

  defp maybe_contains(query, _term), do: query

  # Map a persisted log to its console-counter key, mirroring the live category
  # derivation; `nil` means the row does not feed any of the four card counters.
  @spec counter_key(AgentLog.t()) :: :responses | :tools | :hooks | :thinking | nil
  defp counter_key(%AgentLog{event_type: :tool_call}), do: :tools
  defp counter_key(%AgentLog{event_type: :tool_result}), do: :tools
  defp counter_key(%AgentLog{event_type: :status}), do: :hooks

  defp counter_key(%AgentLog{event_type: :text_delta, payload: payload}) do
    if payload["thinking"] == true, do: :thinking, else: :responses
  end

  defp counter_key(_log), do: nil

  @spec add_cost(Decimal.t(), Usage.t() | nil) :: Decimal.t()
  defp add_cost(acc, %Usage{cost_usd: %Decimal{} = cost}), do: Decimal.add(acc, cost)
  defp add_cost(acc, _usage), do: acc

  # A runtime-SYNTHESIZED `Event.Error` (idle timeout, non-zero provider exit) has
  # no `raw` wire frame, so `scrubbed.raw` is nil/empty and the diagnostic would be
  # silently dropped. For that case persist the error's own fields (redacted) so the
  # cause survives in `agent_logs.payload`. All other events keep the scrubbed `raw`.
  @spec event_payload(Event.t(), term()) :: map() | nil
  defp event_payload(%Event.Error{} = event, raw) when raw == nil or raw == %{} do
    Redact.scrub_term(%{
      "message" => event.message,
      "reason" => to_string(event.reason),
      "retryable" => event.retryable
    })
  end

  # Persist the canonical text (+ thinking flag) rather than the raw harness frame,
  # so reconnect backfill renders clean chat text — pi's raw `message_end` frame has
  # no top-level "text", which would otherwise dump as JSON in the chat bubble.
  #
  # Store `event.text` VERBATIM (not through `Redact.scrub_term/1`): it is the model's
  # own assistant output — a flat string with no nested credential keys to mask — and the
  # worker-report spill path (`Orchestrator.Tools.spill_report/4`) re-reads this payload to
  # write the complete report file. Routing it through the scrubber capped it at
  # `@max_blob_bytes` (10 KB) and silently amputated long reports with a `…[truncated]`
  # marker (issue worker-report-truncation). The `raw` escape hatch is still scrubbed in
  # `persist_event/2`, so secret redaction is unaffected.
  defp event_payload(%Event.TextDelta{} = event, _raw) do
    %{"text" => event.text, "thinking" => event.thinking?}
  end

  defp event_payload(_event, raw), do: raw

  @spec event_type(Event.t()) :: AgentLog.event_type()
  defp event_type(%Event.SessionStarted{}), do: :session_started
  defp event_type(%Event.TextDelta{}), do: :text_delta
  defp event_type(%Event.ToolCall{}), do: :tool_call
  defp event_type(%Event.ToolResult{}), do: :tool_result
  defp event_type(%Event.Usage{}), do: :usage
  defp event_type(%Event.Status{}), do: :status
  defp event_type(%Event.Done{}), do: :done
  defp event_type(%Event.Error{}), do: :error

  defp usage_params(%Event.Usage{} = event) do
    %{
      input_tokens: event.input_tokens,
      output_tokens: event.output_tokens,
      cache_read: event.cache_read,
      cache_creation: event.cache_creation,
      cost_usd: Usage.cost_to_decimal(event.cost_usd)
    }
  end

  defp usage_params(%Event.Done{cost_usd: cost}) when is_float(cost) do
    %{cost_usd: Usage.cost_to_decimal(cost)}
  end

  defp usage_params(_event), do: nil
end
