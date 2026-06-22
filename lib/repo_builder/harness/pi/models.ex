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
  @windows_key {__MODULE__, :windows}
  @ttl_ms 10 * 60 * 1000

  @doc "The models pi offers for `provider` (latest run), or `[]` when unknown/disabled."
  @spec list(String.t() | nil) :: [String.t()]
  def list(provider), do: Map.get(all(), to_string(provider), [])

  @doc """
  The advertised context-window size (tokens) for a pi `model`, or `nil` when unknown,
  un-advertised, disabled (test env), or pi is absent. Sourced live from the `context`
  column of `pi --list-models` (e.g. `200K`, `204.8K`, `1M`) and cached on the same TTL
  as `all/0`. Fail-soft: a cold/stale cache kicks a background refresh and returns the
  last-known value meanwhile.
  """
  @spec context_window(String.t() | nil) :: pos_integer() | nil
  def context_window(nil), do: nil

  def context_window(model) when is_binary(model) do
    Map.get(windows(), model)
  end

  @doc """
  The full cached `%{model => pos_integer()}` context-window map. Triggers a background
  refresh when cold or stale; returns the last-known map meanwhile (`%{}` when disabled).
  """
  @spec windows() :: %{String.t() => pos_integer()}
  def windows do
    if enabled?(), do: cached_windows(), else: %{}
  end

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

  @spec cached_windows() :: %{String.t() => pos_integer()}
  defp cached_windows do
    case :persistent_term.get(@windows_key, nil) do
      {windows, fetched_at} ->
        if stale?(fetched_at), do: refresh_async()
        windows

      nil ->
        refresh_async()
        %{}
    end
  end

  @doc "Refresh the cache in the background (non-blocking, unlinked)."
  @spec refresh_async() :: :ok
  def refresh_async do
    _ = if enabled?(), do: Task.start(fn -> refresh() end)
    :ok
  end

  @doc "Synchronously re-run `pi --list-models` and update the cache."
  @spec refresh() :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def refresh do
    with exe when is_binary(exe) <- System.find_executable("pi"),
         {out, 0} <- System.cmd(exe, ["--list-models"], stderr_to_stdout: true) do
      models = parse(out)
      now = System.monotonic_time(:millisecond)
      :persistent_term.put(@key, {models, now})
      :persistent_term.put(@windows_key, {parse_windows(out), now})
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

  @doc """
  Parse `pi --list-models` output into `%{model => pos_integer()}` from the `context`
  column (column 3: `provider model context …`). Tolerates rows with no context column
  or an unparseable value (omits that model) and skips the header.
  """
  @spec parse_windows(String.t()) :: %{String.t() => pos_integer()}
  def parse_windows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &window_row/2)
  end

  @spec window_row(String.t(), %{String.t() => pos_integer()}) :: %{String.t() => pos_integer()}
  defp window_row(line, acc) do
    case String.split(line) do
      ["provider" | _] -> acc
      [_provider, model, context | _] -> put_window(acc, model, parse_context_size(context))
      _ -> acc
    end
  end

  @spec put_window(%{String.t() => pos_integer()}, String.t(), pos_integer() | nil) ::
          %{String.t() => pos_integer()}
  defp put_window(acc, _model, nil), do: acc
  defp put_window(acc, model, size) when is_integer(size), do: Map.put(acc, model, size)

  # Convert a pi context-column token (`200K`, `204.8K`, `1M`, or a bare integer) into a
  # token count. Returns nil for anything non-positive or unrecognized.
  @spec parse_context_size(String.t()) :: pos_integer() | nil
  defp parse_context_size(token) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)([KkMm])?$/, String.trim(token)) do
      [_full, number, suffix] -> scale(number, suffix)
      [_full, number] -> scale(number, "")
      _ -> nil
    end
  end

  @spec scale(String.t(), String.t()) :: pos_integer() | nil
  defp scale(number, suffix) do
    multiplier =
      case String.downcase(suffix) do
        "k" -> 1_000
        "m" -> 1_000_000
        _ -> 1
      end

    case Float.parse(number) do
      {value, _rest} ->
        size = round(value * multiplier)
        if size > 0, do: size, else: nil

      :error ->
        nil
    end
  end

  @spec enabled?() :: boolean()
  defp enabled?, do: Application.get_env(:repo_builder, :pi_models_discovery, true)

  @spec stale?(integer()) :: boolean()
  defp stale?(fetched_at), do: System.monotonic_time(:millisecond) - fetched_at > @ttl_ms
end
