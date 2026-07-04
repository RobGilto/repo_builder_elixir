defmodule RepoBuilder.Orchestrator.Tools.Shared do
  @moduledoc """
  Cross-domain helpers shared by the `RepoBuilder.Orchestrator.Tools.*` domain
  modules (audit F3 decomposition). Everything here was extracted VERBATIM from
  the original monolithic `Orchestrator.Tools` so tool behaviour is byte-identical:
  argument fetching/normalization, reason stringification, orchestrator lookups,
  log summarization/truncation, and the console broadcast seams.
  """

  alias RepoBuilder.Agents
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators

  # Max characters of worker text surfaced through `check_agent_status` (issue-2541).
  # Bounded to keep the tool result small even at limit=20 (the platform has a known
  # large-tool-result stdout-overflow concern — see issue-log-2389). The reporting clause
  # (`Agents.worker_reporting_clause/0`) interpolates this so the documented limit never
  # drifts from the enforced one.
  @worker_text_cap 2_000

  # Changeset failures are stringified at the boundary (`changeset_reason/1`), so a
  # reason that escapes a tool is always an atom or a string.
  @type reason :: atom() | String.t()
  @type result :: {:ok, map()} | {:error, reason()}

  @doc "The shared cap on worker text surfaced through tool results (issue-2541)."
  # The literal-value spec is deliberate (Dialyzer :underspecs): it is self-enforcing —
  # changing `@worker_text_cap` without updating it fails `mix dialyzer`.
  @spec worker_text_cap() :: 2_000
  def worker_text_cap, do: @worker_text_cap

  @doc "Fetch a required non-empty string argument, or a normalized error."
  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def fetch_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  @doc "A trimmed-blank or non-binary value becomes nil; any other string passes through."
  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  def blank_to_nil(_value), do: nil

  @doc "Normalize an arbitrary failure term into the tool-layer `reason()` shape."
  @spec normalize_reason(term()) :: reason()
  def normalize_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  def normalize_reason(reason), do: inspect(reason)

  @doc "Stringify a changeset failure at the tool boundary (never leaks the changeset)."
  @spec changeset_reason(Ecto.Changeset.t()) :: String.t()
  def changeset_reason(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    case errors do
      %{name: [_ | _]} -> "duplicate or invalid name"
      _ -> "invalid agent: #{inspect(errors)}"
    end
  end

  @doc "Put `key` only when `value` is present (nil leaves the map untouched)."
  @spec put_present(map(), String.t(), term()) :: map()
  def put_present(params, _key, nil), do: params
  def put_present(params, key, value), do: Map.put(params, key, value)

  @doc "A positive integer passes through; anything else yields the default."
  @spec positive_int(term(), pos_integer()) :: pos_integer()
  def positive_int(n, _default) when is_integer(n) and n > 0, do: n
  def positive_int(_n, default), do: default

  @spec to_iso(DateTime.t() | nil) :: String.t() | nil
  def to_iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def to_iso(_other), do: nil

  @spec decimal_to_string(Decimal.t() | nil) :: String.t() | nil
  def decimal_to_string(%Decimal{} = cost), do: Decimal.to_string(cost)
  def decimal_to_string(_other), do: nil

  @doc """
  Codepoint-based truncation that never splits a multibyte UTF-8 char; an overflow
  is marked with the actionable `report_file` pointer (issue worker-report-truncation).
  """
  @spec truncate_text(String.t(), pos_integer()) :: String.t()
  def truncate_text(text, cap) do
    if String.length(text) <= cap,
      do: text,
      else: String.slice(text, 0, cap) <> truncation_marker(cap)
  end

  # Actionable truncation marker: when `final_message` overflows, the platform spills the
  # full text to a file and returns its path as `report_file` (issue worker-report-
  # truncation) — point the coordinator there rather than at a re-dispatch loop. Kept short
  # so it does not itself bloat the tool result.
  @spec truncation_marker(pos_integer()) :: String.t()
  defp truncation_marker(cap),
    do:
      "… (truncated at #{cap} chars — read this result's `report_file` path for the full output, or ask the worker for an ai_docs/ file)"

  @doc "Compact event summary for tool tails; content-bearing events carry a capped text."
  @spec log_summary(Logs.AgentLog.t()) :: %{optional(String.t()) => String.t() | nil}
  def log_summary(log) do
    base = %{"event_type" => to_string(log.event_type), "at" => to_iso(log.inserted_at)}

    case log_summary_text(log) do
      nil -> base
      text -> Map.put(base, "text", truncate_text(text, @worker_text_cap))
    end
  end

  @doc "Content-bearing events surface a text excerpt (issue-2541); others stay compact."
  @spec log_summary_text(Logs.AgentLog.t()) :: String.t() | nil
  def log_summary_text(%{event_type: :text_delta, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["text"])

  def log_summary_text(%{event_type: :done, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["result"]) || blank_to_nil(payload["final_text"])

  def log_summary_text(%{event_type: :error, payload: payload}) when is_map(payload),
    do: blank_to_nil(payload["message"])

  def log_summary_text(_log), do: nil

  @doc """
  The commanding orchestrator's bound project id (orchestrator↔project binding), or nil
  for a platform orchestrator / unknown id. Stamped onto every worker it spawns.
  """
  @spec orchestrator_project_id(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def orchestrator_project_id(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> orchestrator.project_id
      {:error, :not_found} -> nil
    end
  end

  @doc """
  The orchestrator's configured working directory (the cwd its workers run in), or
  nil when unset/unknown — in which case the worker gets an isolated workspace.
  """
  @spec orchestrator_working_dir(Ecto.UUID.t()) :: String.t() | nil
  def orchestrator_working_dir(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> blank_to_nil(orchestrator.working_dir)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Map the context's `:not_found` to the tool-layer `:orchestrator_not_found` reason
  (mirrors `resolve_harness/2`).
  """
  @spec fetch_orchestrator(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, reason()}
  def fetch_orchestrator(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> {:ok, orchestrator}
      {:error, :not_found} -> {:error, :orchestrator_not_found}
    end
  end

  @doc "Resolve the harness from explicit args, else the orchestrator's own harness."
  @spec resolve_harness(Ecto.UUID.t(), map()) :: {:ok, String.t()} | {:error, reason()}
  def resolve_harness(orchestrator_id, args) do
    case blank_to_nil(args["harness"]) do
      nil ->
        case Orchestrators.fetch(orchestrator_id) do
          {:ok, orchestrator} -> {:ok, orchestrator.harness}
          {:error, :not_found} -> {:error, :orchestrator_not_found}
        end

      harness ->
        {:ok, harness}
    end
  end

  @doc "The worker's real provider (rides in `config`, not the closed enum column)."
  @spec worker_provider(Agents.Agent.t()) :: String.t() | nil
  def worker_provider(%{config: config}), do: blank_to_nil(config["provider"])

  @spec broadcast_ledger(Ecto.UUID.t()) :: :ok
  def broadcast_ledger(orchestrator_id),
    do: Dashboard.broadcast_ledger_updated(orchestrator_id, Ledgers.view(orchestrator_id))

  @spec broadcast_workstreams(Ecto.UUID.t()) :: :ok
  def broadcast_workstreams(orchestrator_id),
    do:
      Dashboard.broadcast_workstreams(orchestrator_id, Workstreams.list_records(orchestrator_id))
end
