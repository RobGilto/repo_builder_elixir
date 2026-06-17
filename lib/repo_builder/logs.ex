defmodule RepoBuilder.Logs do
  @moduledoc """
  Context for canonical-event persistence and observability reads (BUILD_PROMPT.md
  §8). The only `Repo` caller for `agent_logs`/`system_logs`.

  `persist_event/2` redacts the event's `raw` (secrets never hit the DB, §4.1),
  maps the variant to an `event_type`, rolls usage into the embedded `Usage` value
  object (float→Decimal boundary), and inserts one `agent_logs` row.
  """
  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 2]

  alias RepoBuilder.Harness.{Event, Redact}
  alias RepoBuilder.Logs.{AgentLog, SystemLog, Usage}
  alias RepoBuilder.Repo

  @doc """
  Redact, map, and persist one canonical event as an `agent_logs` row.

  `attrs` must carry `:agent_id` (the FK) and `:session_id`.
  """
  @spec persist_event(Event.t(), map()) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  def persist_event(event, attrs) do
    scrubbed = Redact.scrub(event)

    params = %{
      agent_id: attrs[:agent_id],
      session_id: attrs[:session_id],
      event_type: event_type(event),
      harness: to_string(event.harness),
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

  `attrs` must carry `:orchestrator_id` and `:session_id`.
  """
  @spec persist_orchestrator_event(Event.t(), %{
          required(:orchestrator_id) => Ecto.UUID.t(),
          required(:session_id) => String.t()
        }) :: {:ok, AgentLog.t()} | {:error, Ecto.Changeset.t()}
  def persist_orchestrator_event(event, attrs) do
    scrubbed = Redact.scrub(event)

    params = %{
      orchestrator_id: attrs[:orchestrator_id],
      session_id: attrs[:session_id],
      event_type: event_type(event),
      harness: to_string(event.harness),
      payload: event_payload(event, scrubbed.raw),
      usage: usage_params(event)
    }

    %AgentLog{}
    |> AgentLog.changeset(params)
    |> Repo.insert()
  end

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
  """
  @spec list_recent_global(pos_integer()) :: [AgentLog.t()]
  def list_recent_global(limit \\ 500) do
    AgentLog
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

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

  # --- private ---

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
  defp event_payload(%Event.TextDelta{} = event, _raw) do
    Redact.scrub_term(%{"text" => event.text, "thinking" => event.thinking?})
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
