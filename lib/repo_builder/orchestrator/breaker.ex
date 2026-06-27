defmodule RepoBuilder.Orchestrator.Breaker do
  @moduledoc """
  A native, ETS-backed circuit breaker (self-healing orchestrator, Phase 4) — no new hex dep
  (`jlouis/fuse` is a drop-in alternative if we later prefer a battle-tested lib).

  Keyed by harness/model/tool/worker-role, it tracks consecutive failures so the leader
  STOPS hammering a broken path and reroutes to another roster tier instead of burning budget.

  States, per key:

    * `:closed`   — healthy; `ask/1` returns `:ok`. `fail/1` increments the failure count.
    * `:open`     — past `breaker_max_failures` consecutive failures; `ask/1` fails fast with
      `{:error, :open}` until `breaker_cooldown_ms` elapses.
    * half-open   — once the cooldown elapses an `:open` key admits a trial (`ask/1` returns
      `:ok`); the next `succeed/1` closes it, the next `fail/1` re-opens it (fresh cooldown).

  The GenServer owns a public named ETS table so `ask/1` is a lock-free direct read; the
  mutating `fail/1`/`succeed/1` are serialized through it. It holds NO Repo state, so it is
  safe to supervise alongside the session runtime and to exercise in tests.
  """
  use GenServer

  @table :orchestrator_breaker
  @default_max_failures 3
  @default_cooldown_ms 60_000

  # ETS row: {key, status :: :closed | :open, failures :: non_neg_integer(), opened_at_ms}
  @type status :: :closed | :open
  @type key :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @doc "Stable breaker key for a `{harness, model}` worker dispatch path."
  @spec key(String.t() | nil, String.t() | nil) :: key()
  def key(harness, model), do: "#{harness || "?"}:#{model || "?"}"

  @doc """
  Ask whether a path is allowed. `:ok` when closed (or `:open` past its cooldown — a trial);
  `{:error, :open}` while the breaker is open and cooling. Lock-free direct ETS read; fails
  OPEN (`:ok`) if the breaker isn't running, so a dead breaker never wedges dispatch.
  """
  @spec ask(key()) :: :ok | {:error, :open}
  def ask(key) do
    case lookup(key) do
      {_key, :open, _failures, opened_at} ->
        if now() - opened_at >= cooldown_ms(), do: :ok, else: {:error, :open}

      _closed_or_absent ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Record a failure for `key` (trips to `:open` past the threshold). Serialized."
  @spec fail(key()) :: :ok
  def fail(key), do: call_if_up({:fail, key})

  @doc "Record a success for `key` (closes the breaker and zeroes the count). Serialized."
  @spec succeed(key()) :: :ok
  def succeed(key), do: call_if_up({:succeed, key})

  @doc "The current status for `key` (`:closed` for an absent/healthy key). For inspection/tests."
  @spec status(key()) :: status()
  def status(key) do
    case lookup(key) do
      {_key, status, _failures, _opened_at} -> status
      _absent -> :closed
    end
  rescue
    ArgumentError -> :closed
  end

  @doc "Clear all breaker state (test helper)."
  @spec reset() :: :ok
  def reset, do: call_if_up(:reset)

  # --- server ---

  @impl true
  def handle_call({:fail, key}, _from, state) do
    failures = current_failures(key) + 1

    if failures >= max_failures() do
      :ets.insert(@table, {key, :open, failures, now()})
    else
      :ets.insert(@table, {key, :closed, failures, nil})
    end

    {:reply, :ok, state}
  end

  def handle_call({:succeed, key}, _from, state) do
    :ets.insert(@table, {key, :closed, 0, nil})
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # --- private ---

  @spec call_if_up(term()) :: :ok
  defp call_if_up(msg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, msg)
    end
  end

  @spec lookup(key()) :: tuple() | nil
  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [row] -> row
      [] -> nil
    end
  end

  @spec current_failures(key()) :: non_neg_integer()
  defp current_failures(key) do
    case lookup(key) do
      {_key, _status, failures, _opened_at} -> failures
      _absent -> 0
    end
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :orchestrator, [])

  @spec max_failures() :: pos_integer()
  defp max_failures, do: config()[:breaker_max_failures] || @default_max_failures

  @spec cooldown_ms() :: pos_integer()
  defp cooldown_ms, do: config()[:breaker_cooldown_ms] || @default_cooldown_ms
end
