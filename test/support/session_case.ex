defmodule RepoBuilder.SessionCase do
  @moduledoc """
  Test case for the live session runtime (BUILD_PROMPT.md §6).

  Provides a shared Ecto sandbox (the session GenServer runs in its own process and
  must see the test's connection) and global Mox mode so the spawned `Session.Server`
  can call the injected mock adapter. Use with `async: false`.

  `register_harness/2` injects an adapter via the registry — the single test seam
  (§13) — and restores the registry on exit.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Mox
      import RepoBuilder.SessionCase

      alias RepoBuilder.Harness.Event
      alias RepoBuilder.Session
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(RepoBuilder.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    on_exit(&drain_sessions/0)

    unless tags[:async], do: Mox.set_mox_global()

    :ok
  end

  @spec drain_sessions(non_neg_integer()) :: :ok
  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  @doc "Inject `module` as the adapter for harness `key`, restoring the registry afterwards."
  @spec register_harness(String.t(), module()) :: :ok
  def register_harness(key, module) do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    entry = %{module: module, exe: "true", default_model: nil, price_table: %{}}
    Application.put_env(:repo_builder, :harnesses, Map.put(original, key, entry))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)
    :ok
  end

  @doc "Subscribe the calling (test) process to a live session's event topic."
  @spec subscribe(String.t()) :: :ok
  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:#{agent_id}:events")
  end
end
