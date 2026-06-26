defmodule RepoBuilder.Budget.Guard do
  @moduledoc """
  Live budget circuit breaker (issue-budget-guardrails), modeled on `Session.Admission`.

  The single authoritative answer to "is spend allowed in scope X right now?". It:

    1. loads the enabled `Budget.Cap`s and reconciles each one's spent-so-far from
       `CostCenter.scope_spend/3` on init (so a node restart cannot zero an over-cap
       budget), and re-reconciles periodically (`refresh_ms`) as the slow-path backstop;
    2. attaches a tiny telemetry handler to `[:repo_builder, :cost, :recorded]` that
       forwards each cost roll (with its scope metadata) into the Guard's mailbox, where
       it is accumulated per cap (the hot path — no DB round-trip);
    3. answers `check/1` — denies when the manual kill switch is engaged or a matching
       `:pause`/`:hard_stop` cap is tripped (`:alert` caps never deny);
    4. on a cap crossing `warn_ratio` broadcasts `:budget_warning`; on crossing
       `limit_usd` it **trips** — marks the cap tripped, broadcasts `:budget_tripped` on
       `"budget:events"`, and for `:hard_stop` interrupts every live session in scope;
    5. supports a manual global KILL SWITCH (`engage_kill_switch/1` / `release_all/1`).

  Enforcement fails **open**: if the Guard is mid-restart, `check/1` allows spend (a dead
  breaker must not wedge the platform) and the supervisor re-reconciles it from
  `CostCenter` on the next init. Caps live in Postgres (`RepoBuilder.Budget`).
  """
  use GenServer

  alias RepoBuilder.{Agents, Budget, CostCenter}
  alias RepoBuilder.Budget.{Cap, Scope}

  @registry RepoBuilder.SessionRegistry
  @topic "budget:events"
  @handler_prefix "repo-builder-budget-guard"
  @cost_event [:repo_builder, :cost, :recorded]
  @default_refresh_ms 60_000

  @type breaker_state :: :ok | :warning | :tripped
  @type check_error :: {:budget_exceeded, Cap.t()}

  defmodule State do
    @moduledoc false
    use TypedStruct

    alias RepoBuilder.Budget.Cap

    typedstruct enforce: true do
      field :caps, %{optional(Ecto.UUID.t()) => Cap.t()}, default: %{}
      field :spent, %{optional(Ecto.UUID.t()) => Decimal.t()}, default: %{}
      field :breaker, %{optional(Ecto.UUID.t()) => :ok | :warning | :tripped}, default: %{}
      field :kill_switch?, boolean(), default: false
      field :reconcile?, boolean(), default: true
      # Whether `caps` is sourced from the DB (the normal singleton) vs. seeded with an
      # explicit `caps:` opt (tests). Only DB-backed Guards reload their cap list on refresh.
      field :db_backed?, boolean(), default: true
      field :refresh_ms, pos_integer()
      field :handler_id, String.t()
    end
  end

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Decide whether spend is allowed for the given scope_refs. Denies on the kill switch
  or any matching tripped `:pause`/`:hard_stop` cap. Fails OPEN (`:ok`) if the Guard is
  unavailable, so a dead breaker never wedges the platform.
  """
  @spec check([Scope.scope_ref()], GenServer.server()) :: :ok | {:error, check_error()}
  def check(scope_refs, server \\ __MODULE__) when is_list(scope_refs) do
    GenServer.call(server, {:check, scope_refs})
  catch
    :exit, _ -> :ok
  end

  @doc "Record a cost roll (USD float) against the given scope_refs. Used by tests and the handler."
  @spec note_spend(float(), [Scope.scope_ref()], GenServer.server()) :: :ok
  def note_spend(amount, scope_refs, server \\ __MODULE__) when is_number(amount) do
    GenServer.cast(server, {:spend, amount, scope_refs})
  end

  @doc "Engage the manual global kill switch (panic button): deny all spend + interrupt live sessions."
  @spec engage_kill_switch(GenServer.server()) :: :ok
  def engage_kill_switch(server \\ __MODULE__), do: GenServer.call(server, :engage_kill_switch)

  @doc "Release the kill switch and re-evaluate every cap from current spend (over-cap stays tripped)."
  @spec release_all(GenServer.server()) :: :ok
  def release_all(server \\ __MODULE__), do: GenServer.call(server, :release_all)

  @doc "Clear a tripped cap by restarting its spend window now (stamps `reset_at` via the Budget context)."
  @spec reset_cap(Ecto.UUID.t(), GenServer.server()) :: :ok
  def reset_cap(cap_id, server \\ __MODULE__), do: GenServer.call(server, {:reset_cap, cap_id})

  @doc """
  Force an immediate reload of the active caps from the DB (so caps created/deleted at
  runtime take effect live) followed by a reconcile from CostCenter. Called after any
  operator cap CRUD, and on the periodic timer.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc "Snapshot of caps + spent + breaker state + kill switch, for the LiveView surface."
  @spec snapshot(GenServer.server()) :: %{
          kill_switch?: boolean(),
          caps: [
            %{
              cap: Cap.t(),
              spent: Decimal.t(),
              ratio: float(),
              state: breaker_state()
            }
          ]
        }
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "The PubSub topic budget events are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  # --- callbacks ---

  @impl true
  def init(opts) do
    refresh_ms =
      opts[:refresh_ms] ||
        get_in(Application.get_env(:repo_builder, :budget, []), [:refresh_ms]) ||
        @default_refresh_ms

    reconcile? = Keyword.get(opts, :reconcile?, reconcile_on_boot?())
    handler_id = "#{@handler_prefix}-#{inspect(self())}"

    caps = load_caps(opts, reconcile?)
    caps_by_id = Map.new(caps, fn cap -> {cap.id, cap} end)

    state =
      %State{
        caps: caps_by_id,
        spent: Map.new(caps, fn cap -> {cap.id, Decimal.new(0)} end),
        breaker: Map.new(caps, fn cap -> {cap.id, :ok} end),
        kill_switch?: false,
        reconcile?: reconcile?,
        db_backed?: not is_list(opts[:caps]),
        refresh_ms: refresh_ms,
        handler_id: handler_id
      }
      |> reconcile()

    attach_telemetry(handler_id)
    schedule_refresh(refresh_ms)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %State{handler_id: handler_id}) do
    _ = :telemetry.detach(handler_id)
    :ok
  end

  @impl true
  def handle_call({:check, scope_refs}, _from, %State{kill_switch?: true} = state) do
    {:reply, deny(scope_refs, state, kill_switch_cap()), state}
  end

  def handle_call({:check, scope_refs}, _from, %State{} = state) do
    case tripped_blocking_cap(scope_refs, state) do
      nil -> {:reply, :ok, state}
      %Cap{} = cap -> {:reply, {:error, {:budget_exceeded, cap}}, state}
    end
  end

  def handle_call(:engage_kill_switch, _from, %State{} = state) do
    broadcast({:kill_switch, :engaged})
    interrupt_in_scope(Scope.global())
    {:reply, :ok, %{state | kill_switch?: true}}
  end

  def handle_call(:release_all, _from, %State{} = state) do
    broadcast({:kill_switch, :released})
    {:reply, :ok, reconcile(%{state | kill_switch?: false})}
  end

  def handle_call({:reset_cap, cap_id}, _from, %State{} = state) do
    {:reply, :ok, reset_one(state, cap_id)}
  end

  def handle_call(:refresh, _from, %State{} = state) do
    {:reply, :ok, reconcile(reload_caps(state))}
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_cast({:spend, amount, scope_refs}, %State{} = state) do
    {:noreply, apply_spend(state, amount, scope_refs)}
  end

  @impl true
  def handle_info(:refresh, %State{refresh_ms: ms} = state) do
    schedule_refresh(ms)
    {:noreply, reconcile(reload_caps(state))}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # --- spend accumulation (hot path) ---

  @spec apply_spend(State.t(), number(), [Scope.scope_ref()]) :: State.t()
  defp apply_spend(%State{} = state, amount, scope_refs) do
    delta = to_decimal(amount)
    matching = matching_cap_ids(state, scope_refs)

    Enum.reduce(matching, state, fn cap_id, acc ->
      spent = Decimal.add(Map.get(acc.spent, cap_id, Decimal.new(0)), delta)
      acc = %{acc | spent: Map.put(acc.spent, cap_id, spent)}
      evaluate_cap(acc, cap_id)
    end)
  end

  # --- reconciliation (slow path / boot) ---

  # Re-read the active caps from the DB and rebuild `caps`, preserving the live spent/breaker
  # accumulators for caps that still exist (so a reload never loses in-flight spend) while
  # dropping deleted caps and admitting newly-created ones. This is what makes runtime cap
  # CRUD take effect live — without it, `state.caps` only ever changed at boot, so created
  # caps went unenforced and deleted caps lingered as stale in-memory "ghosts". A no-op for
  # Guards seeded with an explicit `caps:` opt (tests), whose source of truth is not the DB.
  @spec reload_caps(State.t()) :: State.t()
  defp reload_caps(%State{db_backed?: false} = state), do: state

  defp reload_caps(%State{} = state) do
    caps_by_id = Map.new(load_caps_from_db(), fn cap -> {cap.id, cap} end)
    ids = Map.keys(caps_by_id)

    %{
      state
      | caps: caps_by_id,
        spent: Map.new(ids, fn id -> {id, Map.get(state.spent, id, Decimal.new(0))} end),
        breaker: Map.new(ids, fn id -> {id, Map.get(state.breaker, id, :ok)} end)
    }
  end

  @spec reconcile(State.t()) :: State.t()
  defp reconcile(%State{reconcile?: false} = state), do: recompute_all(state)

  defp reconcile(%State{} = state) do
    spent =
      Map.new(state.caps, fn {cap_id, cap} ->
        {cap_id, safe_scope_spend(cap)}
      end)

    recompute_all(%{state | spent: spent})
  end

  @spec safe_scope_spend(Cap.t()) :: Decimal.t()
  defp safe_scope_spend(%Cap{} = cap) do
    CostCenter.scope_spend(cap.scope, cap.scope_id || "", window_start(cap))
  rescue
    _ -> Decimal.new(0)
  end

  # Recompute every cap's breaker state from current spent, broadcasting transitions.
  @spec recompute_all(State.t()) :: State.t()
  defp recompute_all(%State{} = state) do
    Enum.reduce(Map.keys(state.caps), state, fn cap_id, acc -> evaluate_cap(acc, cap_id) end)
  end

  # --- breaker state machine ---

  @spec evaluate_cap(State.t(), Ecto.UUID.t()) :: State.t()
  defp evaluate_cap(%State{} = state, cap_id) do
    cap = Map.fetch!(state.caps, cap_id)
    spent = Map.get(state.spent, cap_id, Decimal.new(0))
    prev = Map.get(state.breaker, cap_id, :ok)
    next = breaker_state(cap, spent)

    state = %{state | breaker: Map.put(state.breaker, cap_id, next)}
    maybe_broadcast(prev, next, cap, spent)
    maybe_hard_stop(prev, next, cap)
    state
  end

  @spec breaker_state(Cap.t(), Decimal.t()) :: breaker_state()
  defp breaker_state(%Cap{limit_usd: limit, warn_ratio: ratio}, spent) do
    warn_at = Decimal.mult(limit, Decimal.from_float(ratio))

    cond do
      Decimal.compare(spent, limit) != :lt -> :tripped
      Decimal.compare(spent, warn_at) != :lt -> :warning
      true -> :ok
    end
  end

  @spec maybe_broadcast(breaker_state(), breaker_state(), Cap.t(), Decimal.t()) :: :ok
  defp maybe_broadcast(prev, :tripped, cap, spent) when prev != :tripped,
    do: broadcast({:budget_tripped, cap, spent})

  defp maybe_broadcast(prev, :warning, cap, spent) when prev == :ok,
    do: broadcast({:budget_warning, cap, spent})

  defp maybe_broadcast(_prev, _next, _cap, _spent), do: :ok

  @spec maybe_hard_stop(breaker_state(), breaker_state(), Cap.t()) :: :ok
  defp maybe_hard_stop(prev, :tripped, %Cap{action: :hard_stop} = cap) when prev != :tripped do
    interrupt_in_scope(Cap.scope_ref(cap))
  end

  defp maybe_hard_stop(_prev, _next, _cap), do: :ok

  # --- check decision ---

  @spec tripped_blocking_cap([Scope.scope_ref()], State.t()) :: Cap.t() | nil
  defp tripped_blocking_cap(scope_refs, %State{} = state) do
    state
    |> matching_cap_ids(scope_refs)
    |> Enum.find_value(fn cap_id ->
      cap = Map.fetch!(state.caps, cap_id)

      if Map.get(state.breaker, cap_id) == :tripped and cap.action in [:pause, :hard_stop],
        do: cap
    end)
  end

  @spec matching_cap_ids(State.t(), [Scope.scope_ref()]) :: [Ecto.UUID.t()]
  defp matching_cap_ids(%State{caps: caps}, scope_refs) do
    refs = MapSet.new(scope_refs)

    for {cap_id, cap} <- caps, MapSet.member?(refs, Cap.scope_ref(cap)), do: cap_id
  end

  @spec deny([Scope.scope_ref()], State.t(), Cap.t()) :: {:error, check_error()}
  defp deny(scope_refs, %State{} = state, fallback) do
    cap = tripped_blocking_cap(scope_refs, state) || fallback
    {:error, {:budget_exceeded, cap}}
  end

  # A synthetic cap representing the manual kill switch, so `check/1` returns a uniform
  # `{:budget_exceeded, Cap.t()}` shape even when no DB cap is the cause.
  @spec kill_switch_cap() :: Cap.t()
  defp kill_switch_cap do
    %Cap{
      scope: :global,
      scope_id: "",
      period: :total,
      limit_usd: Decimal.new(0),
      action: :hard_stop,
      enabled: true
    }
  end

  # --- reset ---

  # Restart the cap's spend window (stamps reset_at = now in the DB), then recompute its
  # live spend from the new window so the tripped breaker actually clears — not just until
  # the next recompute reads the same over-cap accumulator.
  @spec reset_one(State.t(), Ecto.UUID.t()) :: State.t()
  defp reset_one(%State{} = state, cap_id) do
    case Budget.reset_cap_window(cap_id) do
      nil ->
        state

      %Cap{} = cap ->
        broadcast({:budget_reset, cap})

        state = %{
          state
          | caps: Map.put(state.caps, cap_id, cap),
            spent: Map.put(state.spent, cap_id, safe_scope_spend(cap)),
            breaker: Map.put(state.breaker, cap_id, :ok)
        }

        evaluate_cap(state, cap_id)
    end
  end

  # --- snapshot ---

  @spec build_snapshot(State.t()) :: map()
  defp build_snapshot(%State{} = state) do
    caps =
      state.caps
      |> Map.values()
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(fn cap ->
        spent = Map.get(state.spent, cap.id, Decimal.new(0))

        %{
          cap: cap,
          spent: spent,
          ratio: ratio(cap, spent),
          state: Map.get(state.breaker, cap.id, :ok)
        }
      end)

    %{kill_switch?: state.kill_switch?, caps: caps}
  end

  @spec ratio(Cap.t(), Decimal.t()) :: float()
  defp ratio(%Cap{limit_usd: %Decimal{} = limit}, %Decimal{} = spent) do
    if Decimal.compare(limit, Decimal.new(0)) == :gt do
      spent |> Decimal.div(limit) |> Decimal.to_float()
    else
      0.0
    end
  end

  defp ratio(_cap, _spent), do: 0.0

  # --- session interrupt sweep (hard stop) ---

  @spec interrupt_in_scope(Scope.scope_ref()) :: :ok
  defp interrupt_in_scope(scope_ref) do
    live_agent_ids()
    |> Enum.filter(&agent_in_scope?(&1, scope_ref))
    |> Enum.each(&safe_interrupt/1)
  end

  @spec live_agent_ids() :: [String.t()]
  defp live_agent_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  @spec agent_in_scope?(String.t(), Scope.scope_ref()) :: boolean()
  defp agent_in_scope?(_agent_id, {:global, _}), do: true

  defp agent_in_scope?(agent_id, {:orchestrator, oid}) do
    cond do
      agent_id == oid -> true
      match?(%{orchestrator_id: ^oid}, Agents.get_agent(agent_id)) -> true
      true -> false
    end
  rescue
    _ -> false
  end

  # No agent→workflow link in the schema; the runner's pre-step check blocks the next
  # step instead of mid-step interrupt for workflow-scoped hard stops.
  defp agent_in_scope?(_agent_id, {:workflow, _}), do: false

  @spec safe_interrupt(String.t()) :: :ok
  defp safe_interrupt(agent_id) do
    _ = RepoBuilder.Session.Supervisor.interrupt(agent_id)
    :ok
  rescue
    _ -> :ok
  end

  # --- helpers ---

  @spec load_caps(keyword(), boolean()) :: [Cap.t()]
  defp load_caps(opts, reconcile?) do
    case opts[:caps] do
      caps when is_list(caps) -> caps
      _ when reconcile? -> load_caps_from_db()
      _ -> []
    end
  end

  @spec load_caps_from_db() :: [Cap.t()]
  defp load_caps_from_db do
    _ = safe_seed_default()
    Budget.list_active_caps()
  rescue
    _ -> []
  end

  @spec reconcile_on_boot?() :: boolean()
  defp reconcile_on_boot? do
    get_in(Application.get_env(:repo_builder, :budget, []), [:reconcile_on_boot?]) != false
  end

  # Inference-only spec (the concrete return narrows below a hand-written supertype).
  defp safe_seed_default do
    Budget.seed_default_cap()
  rescue
    _ -> :ok
  end

  @spec attach_telemetry(String.t()) :: :ok
  defp attach_telemetry(handler_id) do
    case :telemetry.attach(handler_id, @cost_event, &__MODULE__.handle_cost_event/4, %{
           server: self()
         }) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec handle_cost_event([atom()], map(), map(), map()) :: :ok
  def handle_cost_event(_event, %{amount: amount}, metadata, %{server: server})
      when is_number(amount) do
    scope_refs =
      Scope.scopes_for(%{
        orchestrator_id: Map.get(metadata, :orchestrator_id),
        workflow_run_id: Map.get(metadata, :workflow_run_id),
        project_id: Map.get(metadata, :project_id)
      })

    note_spend(amount, scope_refs, server)
  end

  def handle_cost_event(_event, _measurements, _metadata, _config), do: :ok

  @spec schedule_refresh(pos_integer()) :: reference()
  defp schedule_refresh(ms), do: Process.send_after(self(), :refresh, ms)

  # Inference-only spec — the concrete broadcast message types narrow below `term()`.
  defp broadcast(message) do
    _ = Phoenix.PubSub.broadcast(RepoBuilder.PubSub, @topic, message)
    :ok
  end

  # The spend window's lower bound: the later of the period start and any operator
  # `reset_at`. A reset can only ever narrow the window (move the start forward), so a
  # tripped cap clears once the period start passes the reset (or the limit is raised).
  @spec window_start(Cap.t()) :: DateTime.t() | nil
  defp window_start(%Cap{period: period, reset_at: reset_at}) do
    later(since_for(period), reset_at)
  end

  @spec later(DateTime.t() | nil, DateTime.t() | nil) :: DateTime.t() | nil
  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  @spec since_for(Cap.period() | nil) :: DateTime.t() | nil
  defp since_for(:daily),
    do: %{DateTime.utc_now() | hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

  defp since_for(:monthly) do
    now = DateTime.utc_now()
    %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  # A :session window has no calendar boundary — it counts purely from the operator's
  # `reset_at` (via window_start/1's `later/2`). With no reset it spans the cap's lifetime.
  defp since_for(:session), do: nil

  defp since_for(_total), do: nil

  @spec to_decimal(number()) :: Decimal.t()
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
end
