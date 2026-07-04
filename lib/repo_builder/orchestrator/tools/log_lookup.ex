defmodule RepoBuilder.Orchestrator.Tools.LogLookup do
  @moduledoc """
  Log lookup tools: the system-log audit tail (`read_system_logs`) and the
  `log-<n>` reference resolver (`get_logs`, issue orchestrator-log-lookup-tools).
  Extracted verbatim from the monolithic `Orchestrator.Tools` (audit F3) —
  behaviour is byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      decimal_to_string: 1,
      log_summary_text: 1,
      positive_int: 2,
      to_iso: 1,
      truncate_text: 2,
      worker_text_cap: 0
    ]

  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Tools.Shared

  @type result :: Shared.result()

  # Max distinct `log_no` numbers `get_logs` resolves in one call (issue
  # orchestrator-log-lookup-tools). Bounds an enormous `from..to` span (or array) so the
  # tool result can never overflow stdout — same rationale as the shared worker-text cap
  # (see issue-log-2389). A request wider than this is clamped (first N after sort) and
  # flagged `capped` so the orchestrator can narrow/paginate rather than silently lose data.
  @max_log_lookup 100

  @spec read_system_logs(map()) :: result()
  def read_system_logs(args) do
    opts = [
      limit: positive_int(args["limit"], 50),
      offset: non_neg_int(args["offset"], 0),
      level: blank_to_nil(args["level"]),
      message_contains: blank_to_nil(args["message_contains"])
    ]

    logs = opts |> Logs.query_system_logs() |> Enum.map(&system_log_summary/1)
    {:ok, %{"logs" => logs, "count" => length(logs)}}
  end

  @doc """
  Resolve a `log-<n>` reference (single / inclusive range / explicit array) to the
  critical content of each matching `agent_logs` row (issue orchestrator-log-lookup-
  tools). Distinct from `read_system_logs` (the separate system-log audit table) and
  `check_agent_status` (a worker tail by name). Bounded to #{@max_log_lookup} numbers so
  a huge span can't overflow the tool result; numbers with no row are reported under
  `missing`, never as an error.
  """
  @spec get_logs(map()) :: result()
  def get_logs(args) do
    if log_selector?(args) do
      requested = requested_numbers(args)
      capped? = length(requested) > @max_log_lookup
      numbers = Enum.take(requested, @max_log_lookup)
      include_hidden? = args["include_hidden"] == true

      details =
        numbers
        |> Logs.logs_by_numbers(include_hidden?: include_hidden?)
        |> Enum.map(&log_detail/1)

      found = MapSet.new(details, & &1["log_no"])
      missing = Enum.reject(numbers, &MapSet.member?(found, &1))

      {:ok,
       %{
         "logs" => details,
         "count" => length(details),
         "requested" => length(requested),
         "missing" => missing,
         "capped" => capped?
       }}
    else
      {:error, "provide one of: log, from+to, or numbers"}
    end
  end

  # True when the args carry ANY usable log selector — a `numbers` array (even empty/
  # all-unparseable, which yields no rows but is still a request), a parseable `from`/`to`
  # range bound, or a parseable single `log`. Separating selector-presence from the
  # resolved set lets an inverted range (`from > to`) return an empty result rather than
  # the no-selector error.
  @spec log_selector?(map()) :: boolean()
  defp log_selector?(args) do
    is_list(args["numbers"]) or
      not is_nil(parse_log_no(args["from"])) or
      not is_nil(parse_log_no(args["to"])) or
      not is_nil(parse_log_no(args["log"]))
  end

  # The concrete, deduped, ascending number set for a request, in precedence order:
  # `numbers` (array) → `from`+`to` (inclusive range) → `log` (single). Unparseable
  # entries are dropped; an inverted range yields `[]`.
  @spec requested_numbers(map()) :: [integer()]
  defp requested_numbers(args) do
    cond do
      is_list(args["numbers"]) ->
        args["numbers"] |> Enum.map(&parse_log_no/1) |> normalize_numbers()

      is_integer(parse_log_no(args["from"])) and is_integer(parse_log_no(args["to"])) ->
        args["from"]
        |> parse_log_no()
        |> range_list(parse_log_no(args["to"]))
        |> normalize_numbers()

      is_integer(parse_log_no(args["log"])) ->
        [parse_log_no(args["log"])]

      true ->
        []
    end
  end

  @spec range_list(integer(), integer()) :: [integer()]
  defp range_list(from, to) when from <= to, do: Enum.to_list(from..to)
  defp range_list(_from, _to), do: []

  @spec normalize_numbers([integer() | nil]) :: [integer()]
  defp normalize_numbers(numbers) do
    numbers |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  # Parse one log reference into its integer `log_no`: a bare integer, an integer-as-
  # string, or a `"log-<n>"` string (case-insensitive, trimmed). Anything else → nil
  # (dropped). Mirrors `blank_to_nil/1`'s tolerant-input posture.
  @spec parse_log_no(term()) :: integer() | nil
  defp parse_log_no(n) when is_integer(n), do: n

  defp parse_log_no(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace_prefix("log-", "") do
      "" ->
        nil

      digits ->
        case Integer.parse(digits) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp parse_log_no(_value), do: nil

  # Compact critical-info summary of one persisted log for `get_logs`: label, owner,
  # type, harness identity, a capped text excerpt (content-bearing events only),
  # token/cost usage (when present), and timestamp. Reuses the `check_agent_status`
  # excerpt + truncation helpers so the stdout-overflow bound is shared.
  #
  # Inference-only spec — the concrete string-keyed map narrows below a hand-written
  # `map()` (mirrors `maybe_put_log_text/2` / `maybe_put_log_usage/2`).
  defp log_detail(log) do
    %{
      "log" => Logs.log_label(log.log_no),
      "log_no" => log.log_no,
      "owner" => owner_label(log),
      "session_id" => log.session_id,
      "event_type" => to_string(log.event_type),
      "harness" => log.harness,
      "provider" => log.provider,
      "model" => log.model,
      "at" => to_iso(log.inserted_at)
    }
    |> maybe_put_log_text(log)
    |> maybe_put_log_usage(log)
  end

  @spec owner_label(Logs.AgentLog.t()) :: String.t() | nil
  defp owner_label(%{agent_id: id}) when is_binary(id), do: "worker:#{id}"
  defp owner_label(%{orchestrator_id: id}) when is_binary(id), do: "orchestrator:#{id}"
  defp owner_label(_log), do: nil

  # Inference-only spec — the concrete map (optionally with a "text" key) narrows below
  # a hand-written `map()` (mirrors `Shared.log_summary/1`).
  defp maybe_put_log_text(detail, log) do
    case log_summary_text(log) do
      nil -> detail
      text -> Map.put(detail, "text", truncate_text(text, worker_text_cap()))
    end
  end

  # Inference-only spec — usage-less rows omit the key entirely; an unpriced row keeps
  # `cost_usd` nil (the nil-vs-0 distinction). The concrete map narrows below `map()`.
  defp maybe_put_log_usage(detail, %{usage: %Logs.Usage{} = usage}) do
    Map.put(detail, "usage", %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read" => usage.cache_read,
      "cache_creation" => usage.cache_creation,
      "cost_usd" => decimal_to_string(usage.cost_usd)
    })
  end

  defp maybe_put_log_usage(detail, _log), do: detail

  # Inference-only spec (mirrors `positive_int/2`): callers pass a literal default,
  # which dialyzer narrows below a hand-written `non_neg_integer()` second arg.
  defp non_neg_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n, default), do: default

  @spec system_log_summary(Logs.SystemLog.t()) :: map()
  defp system_log_summary(log) do
    %{
      "id" => log.id,
      "level" => to_string(log.level),
      "message" => log.message,
      "at" => to_iso(log.inserted_at)
    }
  end
end
