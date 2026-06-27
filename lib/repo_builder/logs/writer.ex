defmodule RepoBuilder.Logs.Writer do
  @moduledoc """
  Off-hot-path persistence + global-feed broadcast for canonical events
  (issue hot-path-writes, Part A).

  `Session.Server.dispatch/2` fans out the latency-critical per-agent broadcast
  SYNCHRONOUSLY, then `cast`s the event here so the `agent_logs` insert — and the
  `log_no`-bearing global-feed broadcast that depends on it — never head-of-line-block
  that session's next event (the dispatch GenServer is serial).

  Started as a `PartitionSupervisor` of writers: every event for a given durable row
  (`agent_id` or `orchestrator_id`) routes to the SAME partition, so persistence is
  FIFO per row (no out-of-order `log_no`) while different rows persist in parallel.
  Routing is `:erlang.phash2(route_key)` via `{:via, PartitionSupervisor, …}`.

  Failure isolation matches the previous inline contract: a persist failure degrades
  that row's `log_no` to `nil` (the drilldown shows "—") and never crashes — it just
  happens off the session's hot path now. Backpressure: casts queue in the writer's
  mailbox (bounded by convention; a hard shed-load cap is out of scope — note it here).
  """
  use GenServer

  require Logger

  alias RepoBuilder.{Agents, Dashboard, Logs}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.AgentLog

  @sup RepoBuilder.LogsWriterSupervisor

  defmodule Record do
    @moduledoc """
    One unit of deferred work cast from `dispatch/2`: the canonical event plus the
    minimal context needed to persist it and broadcast it on the global feed.
    """
    use TypedStruct

    alias RepoBuilder.Harness.Event

    typedstruct enforce: true do
      field :event, Event.t()
      # The string agent id used for topic attribution / the global-feed broadcast.
      field :agent_id, String.t()
      field :broadcast_feed?, boolean()
      # nil ⇒ no durable persistence (ephemeral run). Otherwise the durable owner kind
      # and its persist context (`Logs.persist_event/2` / `persist_orchestrator_event/2`).
      field :persist, {:agent | :orchestrator, map()} | nil
    end
  end

  # --- client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Enqueue one `Record` for async persistence + global-feed broadcast, routed to the
  partition owning its durable row so per-row ordering holds. Returns immediately
  (`cast`); the caller never blocks on the DB.
  """
  @spec record(Record.t()) :: :ok
  def record(%Record{} = rec) do
    GenServer.cast(
      {:via, PartitionSupervisor, {@sup, route_key(rec)}},
      {:record, rec}
    )
  end

  @doc """
  Block until all work queued for `route_key`'s partition has been processed. Because
  the partition handles its mailbox FIFO, a `call` after a batch of `record/1` casts
  returns only once those casts have persisted + broadcast. The synchronization seam
  for graceful drain and for deterministic tests that read `agent_logs` right after a
  burst of events.
  """
  @spec sync(term()) :: :ok
  def sync(route_key) do
    GenServer.call({:via, PartitionSupervisor, {@sup, route_key}}, :sync)
  end

  @doc """
  Block until EVERY writer partition has drained its mailbox. Used at test teardown so
  an in-flight async insert never races the sandbox connection checkin.
  """
  @spec drain() :: :ok
  def drain do
    @sup
    |> PartitionSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} -> _ = GenServer.call(pid, :sync) end)
  end

  # --- server ---

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:record, %Record{} = rec}, state) do
    log = persist_and_status(rec)
    log_no = log && log.log_no

    if rec.broadcast_feed? do
      # Additive global feed for the multi-layered console (§9): one unified stream
      # across all agents, carrying the durable `log_no` (the `log-<n>` drilldown
      # number). Lands a few hundred microseconds after the per-agent stream now, but
      # still with the correct number — the per-agent stream was never gated on the DB.
      _ = Dashboard.broadcast_event(rec.agent_id, rec.event, log_no)
    end

    {:noreply, state}
  end

  # --- persistence (moved verbatim off `Session.Server.dispatch/2`) ---

  @spec persist_and_status(Record.t()) :: AgentLog.t() | nil
  defp persist_and_status(%Record{persist: {:agent, ctx}, event: event}) do
    # Worker path: status follows lifecycle (always), the row persists only for events
    # that finalize (TextDelta partials never persist — `persist?/1`).
    update_status_quietly(event, ctx.agent_id)

    if persist?(event) do
      # Liveness heartbeat (self-healing Phase 1): a persisted normalized event is real
      # progress — bump `heartbeat_at` so the quiescence/idle-demotion passes track WORK,
      # not raw stdout chatter. Bound to `persist?/1` so it fires once per meaningful event
      # (tool use / message / usage / terminal), NOT once per streamed token. Quiet: a bump
      # failure must never break persistence.
      touch_heartbeat_quietly(ctx.agent_id)
      persist_quietly(:agent, event, ctx)
    end
  end

  defp persist_and_status(%Record{persist: {:orchestrator, ctx}, event: event}) do
    if persist?(event), do: persist_quietly(:orchestrator, event, ctx)
  end

  defp persist_and_status(%Record{persist: nil}), do: nil

  # Token-level partial text deltas are broadcast for the live UI but never written
  # to `agent_logs` (§4) — so an N-token turn persists exactly one finalized row and
  # reconnect backfill renders one clean message instead of replaying token shards.
  @spec persist?(Event.t()) :: boolean()
  defp persist?(%Event.TextDelta{partial?: true}), do: false
  defp persist?(_event), do: true

  # Returns the inserted log so the global feed can broadcast its durable `log_no`;
  # any failure (changeset error, rescue, catch) degrades to `nil` → the drilldown
  # shows "—" for that row, never crashing the writer.
  @spec persist_quietly(:agent | :orchestrator, Event.t(), map()) :: AgentLog.t() | nil
  defp persist_quietly(:agent, event, ctx) do
    case Logs.persist_event(event, ctx) do
      {:ok, %AgentLog{} = log} -> log
      {:error, _changeset} -> nil
    end
  rescue
    error ->
      Logger.warning("persist_event failed: #{inspect(error)}")
      nil
  catch
    _kind, _reason -> nil
  end

  defp persist_quietly(:orchestrator, event, ctx) do
    case Logs.persist_orchestrator_event(event, ctx) do
      {:ok, %AgentLog{} = log} -> log
      {:error, _changeset} -> nil
    end
  rescue
    error ->
      Logger.warning("persist_orchestrator_event failed: #{inspect(error)}")
      nil
  catch
    _kind, _reason -> nil
  end

  # Liveness bump, fail-soft (self-healing Phase 1). Mirrors persist_quietly/2's contract:
  # a DB hiccup degrades to a no-op and never crashes the writer.
  @spec touch_heartbeat_quietly(Ecto.UUID.t()) :: :ok
  defp touch_heartbeat_quietly(agent_id) do
    Agents.touch_heartbeat(agent_id)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec update_status_quietly(Event.t(), Ecto.UUID.t()) :: :ok
  defp update_status_quietly(event, agent_id) do
    status =
      case event do
        %Event.SessionStarted{} -> :running
        # A worker HELD pending external input is a clean, resumable stop — its persistent
        # status is :holding (not :idle), so it stays visible/resumable and is never reaped
        # (issue holding-status-for-blocked-agents). Must precede the generic ok: true clause.
        %Event.Done{reason: :held_pending_input} -> :holding
        %Event.Done{ok: true} -> :idle
        %Event.Done{ok: false} -> :error
        %Event.Error{} -> :error
        _ -> nil
      end

    _ = if status, do: Agents.set_status(agent_id, status)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # --- routing ---

  @spec route_key(Record.t()) :: term()
  defp route_key(%Record{persist: {:agent, %{agent_id: id}}}), do: id
  defp route_key(%Record{persist: {:orchestrator, %{orchestrator_id: id}}}), do: id
  defp route_key(%Record{persist: nil, agent_id: id}), do: id
end
