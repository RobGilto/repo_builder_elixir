defmodule RepoBuilder.Harness.Claude do
  @moduledoc """
  Claude Code CLI adapter (BUILD_PROMPT.md §4.3).

  Spawns `claude -p <prompt> --output-format stream-json --verbose
  --include-partial-messages` (token-level deltas require ALL THREE flags) and
  normalizes the snake_case `stream-json` frames into canonical events. Credentials
  go in `env` (never argv — visible in `ps`). `String.to_existing_atom/1` is never
  used on untrusted keys; the reason enum is mapped through a closed lookup.
  """
  @behaviour RepoBuilder.Harness
  @behaviour RepoBuilder.Harness.Orchestrating

  alias RepoBuilder.Harness.Event

  @ctx %{harness: :claude}

  @impl RepoBuilder.Harness.Orchestrating
  def orchestrator_spawn(_opts, ctx) do
    # Claude natively speaks MCP over HTTP via a declared server file. The bearer
    # token lives in that per-session file under the ephemeral cwd (cleaned up by
    # the runtime) — never in argv (visible in `ps`).
    path = Path.join(ctx.cwd, ".mcp.json")
    File.mkdir_p!(ctx.cwd)
    File.write!(path, mcp_config_json(ctx))

    # `--strict-mcp-config` ⇒ ONLY this generated server loads (no ambient ~/.mcp).
    # The permission skip is emitted by `command/1` (the orchestrator session always
    # carries `config: %{orchestrator: true}`), so orchestrator MCP tool calls never
    # block on an interactive prompt (the headless deadlock, §6) — no duplicate here.
    args =
      ["--mcp-config", path, "--strict-mcp-config"] ++
        ["--append-system-prompt", ctx.system_prompt] ++
        resume_args(ctx.resume_session_id)

    {args, []}
  end

  @spec mcp_config_json(RepoBuilder.Harness.Orchestrating.tool_ctx()) :: String.t()
  defp mcp_config_json(ctx) do
    Jason.encode!(%{
      "mcpServers" => %{
        "repo_builder" => %{
          "type" => "http",
          "url" => "#{ctx.mcp_base_url}/orchestrator/#{ctx.orchestrator_id}/mcp",
          "headers" => %{"Authorization" => "Bearer #{ctx.token}"}
        }
      }
    })
  end

  @spec resume_args(String.t() | nil) :: [String.t()]
  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  @impl true
  def command(opts) do
    base = [
      "-p",
      opts.prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages"
    ]

    # Programmatic permission skip ONLY for autonomous sessions (orchestrator or an
    # explicit `autonomous` config flag) — NEVER a global bypass. A plain worker
    # (no flag) gets no skip, so it still honors interactive permissions (safety).
    # The `opus` alias / full Opus id passes through verbatim; Claude resolves it.
    args =
      base
      |> append_arg(opts[:model], fn model -> ["--model", model] end)
      |> append_flags(permission_args(opts))

    {"claude", args, env(opts), @ctx}
  end

  @spec append_arg([String.t()], term(), (term() -> [String.t()])) :: [String.t()]
  defp append_arg(args, nil, _build), do: args
  defp append_arg(args, value, build), do: args ++ build.(value)

  @spec append_flags([String.t()], [String.t()]) :: [String.t()]
  defp append_flags(args, flags), do: args ++ flags

  @spec permission_args(RepoBuilder.Harness.start_opts()) :: [String.t()]
  defp permission_args(opts) do
    if autonomous?(Map.get(opts, :config, %{})),
      do: ["--dangerously-skip-permissions"],
      else: []
  end

  @spec autonomous?(map()) :: boolean()
  defp autonomous?(config) when is_map(config),
    do: Map.get(config, :orchestrator) == true or Map.get(config, :autonomous) == true

  defp autonomous?(_config), do: false

  @impl true
  def normalize(%{"type" => "system", "subtype" => "init"} = raw, _ctx) do
    {:ok,
     [
       %Event.SessionStarted{
         harness: :claude,
         session_id: to_string(Map.get(raw, "session_id", "")),
         model: Map.get(raw, "model"),
         tools: Map.get(raw, "tools"),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "system", "subtype" => "api_retry"} = raw, _ctx) do
    {:ok,
     [
       %Event.Status{
         harness: :claude,
         kind: :retry,
         attempt: Map.get(raw, "attempt"),
         detail: Map.take(raw, ["max_retries", "retry_delay_ms", "error", "error_status"]),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "system", "subtype" => "plugin_install"} = raw, _ctx) do
    {:ok,
     [
       %Event.Status{
         harness: :claude,
         kind: :plugin_install,
         detail: Map.take(raw, ["status", "name", "error"]),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "system"}, _ctx), do: :skip

  def normalize(%{"type" => "assistant", "message" => message} = raw, _ctx)
      when is_map(message) do
    blocks =
      message
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.flat_map(&assistant_block(&1, raw))

    usage =
      case Map.get(message, "usage") do
        %{} = u -> [usage_event(u, raw)]
        _ -> []
      end

    {:ok, blocks ++ usage}
  end

  def normalize(%{"type" => "user", "message" => message} = raw, _ctx) when is_map(message) do
    case message
         |> Map.get("content", [])
         |> List.wrap()
         |> Enum.flat_map(&user_block(&1, raw)) do
      [] -> :skip
      events -> {:ok, events}
    end
  end

  def normalize(
        %{
          "type" => "stream_event",
          "event" => %{"delta" => %{"type" => "text_delta", "text" => text}}
        } = raw,
        _ctx
      )
      when is_binary(text) do
    {:ok, [%Event.TextDelta{harness: :claude, text: text, partial?: true, raw: raw}]}
  end

  def normalize(%{"type" => "stream_event"}, _ctx), do: :skip

  def normalize(%{"type" => "rate_limit"} = raw, _ctx) do
    {:ok, [%Event.Status{harness: :claude, kind: :rate_limit, detail: raw, raw: raw}]}
  end

  def normalize(%{"type" => "result", "subtype" => "success"} = raw, _ctx) do
    is_error = Map.get(raw, "is_error", false)
    cost = Map.get(raw, "total_cost_usd")
    usage = Map.get(raw, "usage", %{})

    done = %Event.Done{
      harness: :claude,
      ok: not is_error,
      reason: :success,
      duration_ms: Map.get(raw, "duration_ms"),
      num_turns: Map.get(raw, "num_turns"),
      final_text: Map.get(raw, "result"),
      usage: usage,
      cost_usd: cost,
      raw: raw
    }

    if is_map(usage) and map_size(usage) > 0 do
      {:ok, [usage_event(usage, raw, cost), done]}
    else
      {:ok, [done]}
    end
  end

  def normalize(%{"type" => "result", "subtype" => subtype} = raw, _ctx)
      when is_binary(subtype) do
    {:ok,
     [
       %Event.Error{
         harness: :claude,
         message: result_error_message(raw),
         reason: :provider_error,
         status: Map.get(raw, "api_error_status"),
         raw: raw
       }
     ]}
  end

  def normalize(_raw, _ctx), do: :skip

  # --- assistant content blocks ---

  @spec assistant_block(term(), map()) :: [Event.t()]
  defp assistant_block(%{"type" => "text", "text" => text}, raw) when is_binary(text),
    do: [%Event.TextDelta{harness: :claude, text: text, thinking?: false, raw: raw}]

  defp assistant_block(%{"type" => "thinking", "thinking" => text}, raw) when is_binary(text),
    do: [%Event.TextDelta{harness: :claude, text: text, thinking?: true, raw: raw}]

  defp assistant_block(%{"type" => "tool_use", "name" => name} = block, raw) when is_binary(name),
    do: [
      %Event.ToolCall{
        harness: :claude,
        id: Map.get(block, "id"),
        name: name,
        input: Map.get(block, "input", %{}),
        raw: raw
      }
    ]

  defp assistant_block(_block, _raw), do: []

  # --- user content blocks ---

  @spec user_block(term(), map()) :: [Event.t()]
  defp user_block(%{"type" => "tool_result"} = block, raw),
    do: [
      %Event.ToolResult{
        harness: :claude,
        id: Map.get(block, "tool_use_id"),
        is_error: Map.get(block, "is_error", false),
        content: Map.get(block, "content"),
        raw: raw
      }
    ]

  defp user_block(_block, _raw), do: []

  # --- usage ---

  @spec usage_event(map(), map(), float() | nil) :: Event.Usage.t()
  defp usage_event(usage, raw, cost \\ nil) do
    %Event.Usage{
      harness: :claude,
      input_tokens: non_neg(Map.get(usage, "input_tokens")),
      output_tokens: non_neg(Map.get(usage, "output_tokens")),
      cache_read: opt_non_neg(Map.get(usage, "cache_read_input_tokens")),
      cache_creation: opt_non_neg(Map.get(usage, "cache_creation_input_tokens")),
      cost_usd: cost,
      raw: raw
    }
  end

  @spec result_error_message(map()) :: String.t()
  defp result_error_message(raw) do
    case Map.get(raw, "errors") do
      [first | _] ->
        error_text(first)

      _ ->
        if is_binary(raw["result"]),
          do: raw["result"],
          else: "claude result error: #{inspect(raw["subtype"])}"
    end
  end

  @spec error_text(term()) :: String.t()
  defp error_text(text) when is_binary(text), do: text
  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(other), do: inspect(other)

  @spec non_neg(term()) :: non_neg_integer()
  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(_), do: 0

  @spec opt_non_neg(term()) :: non_neg_integer() | nil
  defp opt_non_neg(n) when is_integer(n) and n >= 0, do: n
  defp opt_non_neg(_), do: nil

  @spec env(RepoBuilder.Harness.start_opts()) :: [{String.t(), String.t()}]
  defp env(opts) do
    opts
    |> Map.get(:secrets, %{})
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
