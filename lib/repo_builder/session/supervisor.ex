defmodule RepoBuilder.Session.Supervisor do
  @moduledoc """
  Typed API over the application-started `RepoBuilder.SessionSupervisor`
  (a `DynamicSupervisor`), the `RepoBuilder.SessionRegistry`, and the
  `RepoBuilder.Session.Admission` gate (BUILD_PROMPT.md §5/§6).

  `start_session/1` acquires an admission slot, then starts a `:temporary`
  `Session.Server` child (releasing the slot if the start itself fails). All
  targeting (`stop`, `send_stdin`, `interrupt`) is by the registered agent id.
  """
  alias RepoBuilder.Session.{Admission, Server}

  @sup RepoBuilder.SessionSupervisor
  @registry RepoBuilder.SessionRegistry

  @type start_error :: :at_capacity | term()

  @doc """
  Start a live session for `opts` (`:agent_id`, `:harness`, `:prompt`, and the
  optional `:session_id`/`:model`/`:config`/`:secrets`/`:agent_db_id`).
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, start_error()}
  def start_session(opts) do
    case Admission.acquire() do
      :ok ->
        case DynamicSupervisor.start_child(@sup, {Server, opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Admission.release()
            {:ok, pid}

          {:error, reason} ->
            Admission.release()
            {:error, reason}
        end

      {:error, :at_capacity} = error ->
        error
    end
  end

  @doc "Stop a live session by agent id."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(agent_id) do
    case whereis(agent_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@sup, pid)
    end
  end

  @doc "Resolve the live session pid for an agent id, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Send data to a live session's stdin."
  @spec send_stdin(String.t(), iodata()) :: :ok
  def send_stdin(agent_id, data), do: Server.send_stdin(agent_id, data)

  @doc "Interrupt a live session (SIGTERM→SIGKILL of its child)."
  @spec interrupt(String.t()) :: :ok
  def interrupt(agent_id), do: Server.interrupt(agent_id)
end
