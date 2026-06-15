defmodule RepoBuilder.Session.Admission do
  @moduledoc """
  Live-session concurrency gate (BUILD_PROMPT.md §5).

  A small GenServer holding `{used, max}`. The runtime must `acquire/0` a slot
  before starting a live session; if none is free it gets `{:error, :at_capacity}`
  and queues/rejects rather than exhausting OS processes/fds. `release/0` is
  idempotent (never drops below zero). This is distinct from Oban queue
  concurrency and from the `SessionSupervisor` `max_children` backstop.
  """
  use GenServer

  @type reason :: :at_capacity

  defmodule State do
    @moduledoc false
    use TypedStruct

    typedstruct enforce: true do
      field :used, non_neg_integer(), default: 0
      field :max, pos_integer()
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Acquire a live-session slot, or report capacity exhaustion."
  @spec acquire(GenServer.server()) :: :ok | {:error, reason()}
  def acquire(server \\ __MODULE__), do: GenServer.call(server, :acquire)

  @doc "Release a previously-acquired slot. Idempotent (clamps at zero)."
  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__), do: GenServer.cast(server, :release)

  @doc "Current usage snapshot (for observability/tests)."
  @spec count(GenServer.server()) :: %{used: non_neg_integer(), max: pos_integer()}
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  @impl true
  def init(opts) do
    max =
      opts[:max] ||
        get_in(Application.get_env(:repo_builder, :session, []), [:max_live_sessions]) || 100

    {:ok, %State{used: 0, max: max}}
  end

  @impl true
  def handle_call(:acquire, _from, %State{used: used, max: max} = state) when used < max do
    {:reply, :ok, %{state | used: used + 1}}
  end

  def handle_call(:acquire, _from, %State{} = state) do
    {:reply, {:error, :at_capacity}, state}
  end

  def handle_call(:count, _from, %State{used: used, max: max} = state) do
    {:reply, %{used: used, max: max}, state}
  end

  @impl true
  def handle_cast(:release, %State{used: used} = state) do
    {:noreply, %{state | used: max(used - 1, 0)}}
  end
end
