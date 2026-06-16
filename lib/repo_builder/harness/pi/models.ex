defmodule RepoBuilder.Harness.Pi.Models do
  @moduledoc """
  Live pi model catalog (issue-d follow-up).

  Shells `pi --list-models` and groups its `provider model …` rows into
  `%{provider => [model]}`, cached in `:persistent_term` with a TTL, so the
  orchestrator model dropdown reflects the models pi ACTUALLY offers (pi lists only
  the providers the operator is authed for, and tracks new releases per pi release —
  e.g. `MiniMax-M3`) rather than a hand-maintained static list.

  Fail-soft and non-blocking:

    * when `pi` is absent or errors, the cache stays empty and callers fall back to
      the static registry lists (`Registry.orchestrator_models/2`);
    * reads never block — a cold/stale cache kicks a background refresh and returns
      the last-known (or empty) map;
    * disabled in the test env (`:pi_models_discovery`) so the suite never shells out.
  """
  require Logger

  @key {__MODULE__, :catalog}
  @ttl_ms 10 * 60 * 1000

  @doc "The models pi offers for `provider` (latest run), or `[]` when unknown/disabled."
  @spec list(String.t() | nil) :: [String.t()]
  def list(provider), do: Map.get(all(), to_string(provider), [])

  @doc """
  The full cached `%{provider => [model]}` map. Triggers a background refresh when
  the cache is cold or older than the TTL; returns the last-known map meanwhile.
  """
  @spec all() :: %{String.t() => [String.t()]}
  def all do
    if enabled?(), do: cached(), else: %{}
  end

  @spec cached() :: %{String.t() => [String.t()]}
  defp cached do
    case :persistent_term.get(@key, nil) do
      {models, fetched_at} ->
        if stale?(fetched_at), do: refresh_async()
        models

      nil ->
        refresh_async()
        %{}
    end
  end

  @doc "Refresh the cache in the background (non-blocking, unlinked)."
  @spec refresh_async() :: :ok
  def refresh_async do
    if enabled?(), do: Task.start(fn -> refresh() end)
    :ok
  end

  @doc "Synchronously re-run `pi --list-models` and update the cache."
  @spec refresh() :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def refresh do
    with exe when is_binary(exe) <- System.find_executable("pi"),
         {out, 0} <- System.cmd(exe, ["--list-models"], stderr_to_stdout: true) do
      models = parse(out)
      :persistent_term.put(@key, {models, System.monotonic_time(:millisecond)})
      {:ok, models}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    error ->
      Logger.debug("pi --list-models failed: #{inspect(error)}")
      {:error, :unavailable}
  end

  @doc "Parse `pi --list-models` columnar output into `%{provider => [model]}` (header skipped)."
  @spec parse(String.t()) :: %{String.t() => [String.t()]}
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line) do
        ["provider" | _] -> acc
        [provider, model | _] -> Map.update(acc, provider, [model], &(&1 ++ [model]))
        _ -> acc
      end
    end)
  end

  @spec enabled?() :: boolean()
  defp enabled?, do: Application.get_env(:repo_builder, :pi_models_discovery, true)

  @spec stale?(integer()) :: boolean()
  defp stale?(fetched_at), do: System.monotonic_time(:millisecond) - fetched_at > @ttl_ms
end
