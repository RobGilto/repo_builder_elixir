defmodule RepoBuilder.Explain do
  @moduledoc """
  Ephemeral, read-time "explain these logs" aid (issue-explain).

  An operator selects one or more console event-stream rows and asks the
  orchestrator's configured **Fast** tier to gloss them in one paragraph. This
  context resolves the Fast roster entry, builds a troubleshooting prompt from the
  selected rows' FULL bodies, and starts a one-shot ephemeral runner
  (`RepoBuilder.Explain.Server`) that replies to the caller.

  Nothing here touches `Repo`: roster reads delegate to `RepoBuilder.Orchestrators`
  and the run is dispatched through the harness session runtime with persistence and
  the global feed both disabled — no `agent_logs` row, no console-feed pollution, no
  durable agent.
  """
  alias RepoBuilder.Explain.{Request, Server}
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Orchestrators

  @typedoc "Resolved Fast-tier harness/provider/model."
  @type fast_config :: %{harness: String.t(), provider: String.t() | nil, model: String.t()}

  @typedoc "A selected event-stream row (the in-assign `event_buffer` shape)."
  @type row :: %{
          optional(atom()) => term(),
          log_no: integer() | nil,
          line: integer(),
          category: atom(),
          kind: String.t(),
          agent: String.t(),
          body: String.t(),
          time: String.t()
        }

  @doc """
  Resolve the orchestrator's `fast` roster entry to a usable harness/provider/model.

  Returns `{:error, :no_fast_agent}` when the `fast` tier is unset or its harness or
  model is blank (the operator hasn't picked one under the header's "Agents…" panel).
  """
  @spec fast_config(Orchestrator.t()) :: {:ok, fast_config()} | {:error, :no_fast_agent}
  def fast_config(%Orchestrator{} = orchestrator) do
    entry = Map.get(Orchestrators.agent_models(orchestrator), "fast", %{})

    harness = blank_to_nil(Map.get(entry, "harness"))
    model = blank_to_nil(Map.get(entry, "model"))

    case {harness, model} do
      {h, m} when is_binary(h) and is_binary(m) ->
        {:ok, %{harness: h, provider: blank_to_nil(Map.get(entry, "provider")), model: m}}

      _ ->
        {:error, :no_fast_agent}
    end
  end

  @doc """
  Build the single-paragraph troubleshooting prompt from the selected `rows`.

  Each row is serialized with its FULL `body` (not the 160-char display truncation)
  as `log-<n> [<category>/<kind>] <agent> @ <time>\\n<body>`. The instruction asks
  for ONE paragraph with enough technical detail to act on — no preamble, no bullets.
  """
  @spec build_prompt([row()]) :: String.t()
  def build_prompt(rows) do
    events = Enum.map_join(rows, "\n\n", &serialize_row/1)

    instruction()
    |> Kernel.<>("\n\n")
    |> Kernel.<>(events)
  end

  @doc """
  Resolve the Fast tier, build the prompt from `rows`, and start the ephemeral
  runner. Returns the `request_id` so the caller can correlate the async
  `{:explain_result, request_id, _}` reply. The runner messages `self()`.
  """
  @spec explain(Orchestrator.t(), [row()]) ::
          {:ok, String.t()} | {:error, :no_fast_agent | term()}
  def explain(%Orchestrator{} = orchestrator, rows) do
    with {:ok, config} <- fast_config(orchestrator) do
      request = %Request{
        request_id: generate_request_id(),
        prompt: build_prompt(rows),
        harness: config.harness,
        provider: config.provider,
        model: config.model,
        reply_to: self()
      }

      case Server.start(request) do
        {:ok, _pid} -> {:ok, request.request_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- helpers ---

  @spec instruction() :: String.t()
  defp instruction do
    "You are explaining console/harness log output to a software engineer for " <>
      "troubleshooting. Explain what the following event(s) mean in ONE paragraph, " <>
      "with enough technical detail to act on. No preamble, no bullet lists."
  end

  @spec serialize_row(row()) :: String.t()
  defp serialize_row(row) do
    number = row[:log_no] || row[:line]

    header =
      "log-#{number} [#{row[:category]}/#{row[:kind]}] #{row[:agent]} @ #{row[:time]}"

    header <> "\n" <> to_string(row[:body])
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  @spec generate_request_id() :: String.t()
  defp generate_request_id do
    8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
