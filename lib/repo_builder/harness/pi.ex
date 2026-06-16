defmodule RepoBuilder.Harness.Pi do
  @moduledoc """
  pi CLI adapter (BUILD_PROMPT.md §4.3).

  Spawns `pi --mode json` and normalizes its lifecycle frames
  (`session → agent_start → … → agent_end`, plus `auto_retry_*`). Key pi quirks
  handled here:

    * camelCase field names in tool events (`toolName`, `toolCallId`, `args`,
      `isError`, `result`, `finalError`); the outer `type` and the inner
      `assistantMessageEvent.type` are TWO different discriminators.
    * provider-polymorphic usage: Anthropic-shaped (`input_tokens`/`output_tokens`),
      OpenAI-shaped (`prompt_tokens`/`completion_tokens`), and pi-native
      (`input`/`output` + `cacheRead`/`cacheWrite`).
    * NO per-run USD cost in the stream — `cost_usd` stays nil here; it is derived
      downstream from a price table (M6 `Pricing`).

  The terminal `Done{reason: :clean_exit}` (zai/GLM ends with no `agent_end`) and
  the idle-timeout `Error` are SYNTHESIZED by the §6 runtime, NOT here.
  """
  @behaviour RepoBuilder.Harness
  @behaviour RepoBuilder.Harness.Orchestrating

  alias RepoBuilder.Harness.{Event, Pricing}

  # The pi extension that registers the orchestrator tools (pi ships no MCP, §10).
  @pi_extension Path.join(:code.priv_dir(:repo_builder), "orchestrator/pi_extension")

  @impl RepoBuilder.Harness.Orchestrating
  def orchestrator_spawn(_opts, ctx) do
    # pi has no MCP: tools come from a TypeScript extension loaded with `-e`, whose
    # handlers `fetch` the same MCP/JSON endpoint using the env below (token in env,
    # never argv). Session resume uses `--session <id>`.
    args =
      ["-e", @pi_extension, "--append-system-prompt", ctx.system_prompt] ++
        resume_args(ctx.resume_session_id)

    env = [
      {"PI_ORCH_BASE_URL", "#{ctx.mcp_base_url}/orchestrator/#{ctx.orchestrator_id}/mcp"},
      {"PI_ORCH_TOKEN", ctx.token}
    ]

    {args, env}
  end

  @spec resume_args(String.t() | nil) :: [String.t()]
  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--session", session_id]

  @impl true
  def command(opts) do
    base = ["--mode", "json"]
    model = opts[:model]
    args = if model, do: base ++ ["--model", model], else: base
    # Thread model + price table into the session_ctx so normalize/2 can derive cost
    # (pi reports no USD in its stream — §4.3).
    ctx = %{harness: :pi, model: model, price_table: Map.get(opts, :price_table, %{})}
    {"pi", args ++ [opts.prompt], env(opts), ctx}
  end

  @impl true
  def normalize(%{"type" => "session"} = raw, _ctx) do
    {:ok,
     [
       %Event.SessionStarted{
         harness: :pi,
         session_id: to_string(Map.get(raw, "id", "")),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => type}, _ctx)
      when type in ~w(agent_start turn_start message_start queue_update),
      do: :skip

  def normalize(%{"type" => "compaction" <> _rest}, _ctx), do: :skip

  def normalize(
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta"} = event
        } = raw,
        _ctx
      ) do
    case Map.get(event, "text") do
      text when is_binary(text) ->
        {:ok, [%Event.TextDelta{harness: :pi, text: text, thinking?: false, raw: raw}]}

      _ ->
        :skip
    end
  end

  def normalize(
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "thinking_delta"} = event
        } = raw,
        _ctx
      ) do
    case Map.get(event, "text") || Map.get(event, "thinking") do
      text when is_binary(text) ->
        {:ok, [%Event.TextDelta{harness: :pi, text: text, thinking?: true, raw: raw}]}

      _ ->
        :skip
    end
  end

  def normalize(%{"type" => "message_update"}, _ctx), do: :skip

  def normalize(%{"type" => "message_end"} = raw, ctx) do
    message = Map.get(raw, "message", %{})

    text_events =
      []
      |> append_text(pi_text(message, "text"), false, raw)
      |> append_text(pi_text(message, "thinking"), true, raw)

    usage_events =
      case parse_usage(Map.get(message, "usage"), raw, ctx) do
        %Event.Usage{} = usage -> [usage]
        _ -> []
      end

    case text_events ++ usage_events do
      [] -> :skip
      events -> {:ok, events}
    end
  end

  def normalize(%{"type" => "turn_end", "message" => %{"usage" => usage}} = raw, ctx) do
    case parse_usage(usage, raw, ctx) do
      %Event.Usage{} = event -> {:ok, [event]}
      _ -> :skip
    end
  end

  def normalize(%{"type" => "turn_end"}, _ctx), do: :skip

  def normalize(%{"type" => "tool_execution_start"} = raw, _ctx) do
    {:ok,
     [
       %Event.ToolCall{
         harness: :pi,
         id: Map.get(raw, "toolCallId"),
         name: to_string(Map.get(raw, "toolName", "")),
         input: pi_map(Map.get(raw, "args")),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "tool_execution_end"} = raw, _ctx) do
    {:ok,
     [
       %Event.ToolResult{
         harness: :pi,
         id: Map.get(raw, "toolCallId"),
         is_error: Map.get(raw, "isError", false),
         content: Map.get(raw, "result"),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "agent_end"} = raw, ctx) do
    done = %Event.Done{harness: :pi, ok: true, reason: :agent_end, raw: raw}

    usage =
      raw
      |> Map.get("messages", [])
      |> List.wrap()
      |> List.last()
      |> case do
        %{"usage" => u} -> parse_usage(u, raw, ctx)
        _ -> nil
      end

    case usage do
      %Event.Usage{} = event -> {:ok, [event, done]}
      _ -> {:ok, [done]}
    end
  end

  def normalize(%{"type" => "auto_retry_start"} = raw, _ctx) do
    {:ok,
     [
       %Event.Status{
         harness: :pi,
         kind: :retry,
         attempt: Map.get(raw, "attempt"),
         detail: raw,
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "auto_retry_end", "success" => false} = raw, _ctx) do
    {:ok,
     [
       %Event.Error{
         harness: :pi,
         message: to_string(Map.get(raw, "finalError", "auto-retry exhausted")),
         reason: :auto_retry_exhausted,
         retryable: Map.get(raw, "retryable", false),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "auto_retry_end"}, _ctx), do: :skip

  def normalize(_raw, _ctx), do: :skip

  # --- usage (provider-polymorphic) ---

  @spec parse_usage(term(), map(), map()) :: Event.Usage.t() | nil
  defp parse_usage(usage, raw, ctx) when is_map(usage) do
    input = first_present_int(usage, ["input_tokens", "prompt_tokens", "input"])
    output = first_present_int(usage, ["output_tokens", "completion_tokens", "output"])

    if is_nil(input) and is_nil(output) do
      nil
    else
      in_tokens = input || 0
      out_tokens = output || 0

      %Event.Usage{
        harness: :pi,
        input_tokens: in_tokens,
        output_tokens: out_tokens,
        cache_read:
          first_present_int(usage, ["cache_read", "cacheRead", "cache_read_input_tokens"]),
        cache_creation:
          first_present_int(usage, ["cache_creation", "cacheWrite", "cache_creation_input_tokens"]),
        cost_usd:
          Pricing.derive(
            Map.get(ctx, :model),
            in_tokens,
            out_tokens,
            Map.get(ctx, :price_table, %{})
          ),
        raw: raw
      }
    end
  end

  defp parse_usage(_usage, _raw, _ctx), do: nil

  @spec first_present_int(map(), [String.t()]) :: non_neg_integer() | nil
  defp first_present_int(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end)
  end

  # --- text extraction ---

  @spec pi_text(map(), String.t()) :: String.t() | nil
  defp pi_text(message, key) when is_map(message) do
    cond do
      is_binary(Map.get(message, key)) -> Map.get(message, key)
      is_list(Map.get(message, "content")) -> join_blocks(Map.get(message, "content"), key)
      true -> nil
    end
  end

  defp pi_text(_message, _key), do: nil

  @spec join_blocks([term()], String.t()) :: String.t() | nil
  defp join_blocks(content, kind) do
    joined =
      content
      |> Enum.filter(&match?(%{"type" => ^kind}, &1))
      |> Enum.map(fn block -> Map.get(block, kind) || Map.get(block, "text") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.join("")

    if joined == "", do: nil, else: joined
  end

  @spec append_text([Event.t()], String.t() | nil, boolean(), map()) :: [Event.t()]
  defp append_text(events, text, thinking?, raw) when is_binary(text) and text != "" do
    events ++ [%Event.TextDelta{harness: :pi, text: text, thinking?: thinking?, raw: raw}]
  end

  defp append_text(events, _text, _thinking?, _raw), do: events

  @spec pi_map(term()) :: map()
  defp pi_map(value) when is_map(value), do: value
  defp pi_map(_value), do: %{}

  @spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
  defp env(opts) do
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
