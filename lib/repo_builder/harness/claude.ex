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

  alias RepoBuilder.ExternalApis
  alias RepoBuilder.ExternalApis.Provisioning
  alias RepoBuilder.Harness.{Event, McpTools, Pricing}

  @ctx %{harness: :claude}

  # The orchestrator runs on a model ALIAS (`opus`/`sonnet`/`haiku`) — the CLI resolves
  # each alias to the latest of its family. The seeded price catalog
  # (priv/repo/pricing_seeds.exs) is keyed by the CANONICAL family IDs, so the live
  # estimate lookup must canonicalize the alias first or it misses the catalog and the
  # cost badge shows `—` for the whole turn (issue log-7700). The CLI still receives the
  # alias verbatim; only the pricing lookup is canonicalized. Keep these targets in sync
  # with the seeded catalog keys when a new family/latest model lands.
  @model_aliases %{
    "opus" => "claude-opus-4-8",
    "sonnet" => "claude-sonnet-4-6",
    "haiku" => "claude-haiku-4-5",
    "fable" => "claude-fable-5"
  }

  # The orchestrator is a delegation-only meta-agent: ALL real work goes to worker
  # agents via the bound MCP meta-tools (`RepoBuilder.Orchestrator.Tools`). Claude ships
  # native coding tools that would otherwise be available AND auto-approved (the
  # orchestrator carries `--dangerously-skip-permissions`), so we DENY the native
  # file-mutation/shell/native-subagent tools on the orchestrator spawn — leaving only
  # the MCP tools. Workers NEVER hit `orchestrator_spawn/2`, so they keep these tools.
  @orchestrator_disallowed_tools ~w(Write Edit MultiEdit NotebookEdit Bash BashOutput KillShell Task)

  @impl RepoBuilder.Harness.Orchestrating
  def orchestrator_spawn(_opts, ctx) do
    # Claude natively speaks MCP over HTTP via a declared server file. The bearer
    # token lives in that per-session file under the ephemeral cwd (cleaned up by
    # the runtime) — never in argv (visible in `ps`). Use an ABSOLUTE path: the
    # session cwd is relative to the BEAM root, but Claude runs WITH its cwd set to
    # that workspace, so a relative `--mcp-config` would resolve against it twice.
    cwd = Path.expand(ctx.cwd)
    path = Path.join(cwd, ".mcp.json")
    File.mkdir_p!(cwd)
    File.write!(path, mcp_config_json(ctx))

    # `--strict-mcp-config` ⇒ ONLY this generated server loads (no ambient ~/.mcp).
    # The permission skip is emitted by `command/1` (the orchestrator session always
    # carries `config: %{orchestrator: true}`), so orchestrator MCP tool calls never
    # block on an interactive prompt (the headless deadlock, §6) — no duplicate here.
    args =
      ["--mcp-config", path, "--strict-mcp-config"] ++
        ["--disallowedTools" | @orchestrator_disallowed_tools] ++
        [system_prompt_flag(ctx.system_prompt_mode), ctx.system_prompt] ++
        resume_args(ctx.resume_session_id)

    {args, []}
  end

  # Map the operator-chosen mode to Claude's prompt flag: `:append` keeps the
  # default coding-agent prompt and adds ours; `:replace` swaps it out entirely.
  @spec system_prompt_flag(:append | :replace) :: String.t()
  defp system_prompt_flag(:replace), do: "--system-prompt"
  defp system_prompt_flag(_append), do: "--append-system-prompt"

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
      |> append_flags(effort_args(opts[:reasoning_effort]))
      |> append_flags(worker_mcp_args(opts))

    {"claude", args, env(opts), @ctx}
  end

  # Worker MCP binding (issue firecrawl-grant): when a non-orchestrator worker's
  # config grants research tools, write a `.mcp.json` into the session cwd declaring
  # their stdio servers (key referenced as `${FIRECRAWL_API_KEY}`, never inlined) and
  # return `--mcp-config <abs path> --strict-mcp-config --allowedTools <patterns>` so
  # the autonomous worker can call them without an interactive prompt. The orchestrator
  # path (config carries `:orchestrator`) declares MCP via `orchestrator_spawn/2`, so
  # it is skipped here. No tools ⇒ `[]` (a plain worker is byte-for-byte unchanged).
  @spec worker_mcp_args(RepoBuilder.Harness.start_opts()) :: [String.t()]
  defp worker_mcp_args(opts) do
    config = Map.get(opts, :config, %{})

    if orchestrator_config?(config) do
      []
    else
      # MERGE the static firecrawl catalog with the dynamic, operator-registered API
      # registry (issue-external-api-mcp-provisioning), resolved against the worker's
      # bound project scope. Skip the file ONLY when BOTH are empty — a plain worker is
      # byte-for-byte unchanged.
      tools = McpTools.enabled(config["tools"])
      apis = ExternalApis.fetch_by_names(opts[:project_id], config["apis"] || [])

      servers = Map.merge(McpTools.mcp_servers(tools), Provisioning.mcp_servers(apis))
      allowed = McpTools.allowed_tools(tools) ++ Provisioning.allowed_tools(apis)

      if servers == %{} do
        []
      else
        cwd = Path.expand(opts.cwd)
        path = Path.join(cwd, ".mcp.json")
        File.mkdir_p!(cwd)
        File.write!(path, Jason.encode!(%{"mcpServers" => servers}))

        ["--mcp-config", path, "--strict-mcp-config"] ++
          ["--allowedTools" | allowed]
      end
    end
  end

  @spec orchestrator_config?(map()) :: boolean()
  defp orchestrator_config?(config) when is_map(config),
    do: Map.get(config, :orchestrator) == true

  defp orchestrator_config?(_config), do: false

  # Map the harness-blind reasoning effort to Claude's `--effort` flag (print-mode,
  # model-dependent levels). Claude has NO `off` — the lowest level is `low`, so both
  # `:default` and `:off` omit the flag (model default). `:max` is Claude's top level.
  @spec effort_args(RepoBuilder.Harness.reasoning_effort() | nil) :: [String.t()]
  defp effort_args(:low), do: ["--effort", "low"]
  defp effort_args(:medium), do: ["--effort", "medium"]
  defp effort_args(:high), do: ["--effort", "high"]
  defp effort_args(:max), do: ["--effort", "max"]
  defp effort_args(_default_or_off_or_nil), do: []

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

  def normalize(%{"type" => "assistant", "message" => message} = raw, ctx)
      when is_map(message) do
    blocks =
      message
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.flat_map(&assistant_block(&1, raw))

    usage =
      case Map.get(message, "usage") do
        %{} = u -> [usage_event(u, raw, ctx)]
        _ -> []
      end

    # A synthetic assistant frame carrying a transient provider error (`"error": "rate_limit"`
    # / `"overloaded"`, model `"<synthetic>"`; issue rate-limit-stall) surfaces a
    # `Status{kind: :rate_limit}` so the turn is treated as throttling, not stagnation.
    {:ok, transient_status(raw) ++ blocks ++ usage}
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

  def normalize(%{"type" => "result", "subtype" => "success"} = raw, ctx) do
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
      # Cost lives on Done only — see issue-claude-cost; double-counted otherwise.
      # The terminal Usage carries cost_usd: nil (estimated_cost_usd still derived).
      {:ok, [usage_event(usage, raw, ctx), done]}
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

  # A one-element `Status{kind: :rate_limit}` list when the frame carries a transient
  # provider error marker, else `[]` (issue rate-limit-stall).
  @transient_errors ~w(rate_limit overloaded)
  @spec transient_status(map()) :: [Event.Status.t()]
  defp transient_status(%{"error" => error} = raw) when error in @transient_errors,
    do: [%Event.Status{harness: :claude, kind: :rate_limit, detail: raw, raw: raw}]

  defp transient_status(_raw), do: []

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

  # The authoritative cost is NEVER stamped on a claude Usage — it lives on Done only
  # (single-carrier invariant, issue-claude-cost). Usage carries only the token-derived
  # `estimated_cost_usd` display signal; `cost_usd` is always nil.
  @spec usage_event(map(), map(), map()) :: Event.Usage.t()
  defp usage_event(usage, raw, ctx) do
    in_tokens = non_neg(Map.get(usage, "input_tokens"))
    out_tokens = non_neg(Map.get(usage, "output_tokens"))
    cache_read = opt_non_neg(Map.get(usage, "cache_read_input_tokens"))
    cache_creation = opt_non_neg(Map.get(usage, "cache_creation_input_tokens"))

    %Event.Usage{
      harness: :claude,
      input_tokens: in_tokens,
      output_tokens: out_tokens,
      cache_read: cache_read,
      cache_creation: cache_creation,
      cost_usd: nil,
      estimated_cost_usd:
        Pricing.derive(
          canonical_model(Map.get(ctx, :model)),
          %{
            input: in_tokens,
            output: out_tokens,
            cache_read: cache_read,
            cache_creation: cache_creation
          },
          Map.get(ctx, :price_table, %{})
        ),
      raw: raw
    }
  end

  # Resolve an orchestrator model alias to its canonical catalog ID for the PRICING
  # lookup only (the CLI still gets the alias). Unknown/unaliased models and `nil` pass
  # through unchanged, so a genuinely unpriced model still derives a nil estimate rather
  # than being masked (issue log-7700).
  @spec canonical_model(String.t() | nil) :: String.t() | nil
  defp canonical_model(model) when is_binary(model), do: Map.get(@model_aliases, model, model)
  defp canonical_model(nil), do: nil

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
