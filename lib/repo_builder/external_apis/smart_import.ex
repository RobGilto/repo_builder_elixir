defmodule RepoBuilder.ExternalApis.SmartImport do
  @moduledoc """
  Smart-import orchestration for the Registered APIs registry
  (issue-external-api-mcp-provisioning).

  Deterministic-first, agent-fallback: `import/2` runs the pure
  `RepoBuilder.ExternalApis.McpImport` parser; on a recognized config it returns the
  `RepoBuilder.ExternalApis.ImportResult` SYNCHRONOUSLY (no LLM, works with no Fast tier).
  When the parser reports `{:needs_agent, _}` (free-form / unstructured input), it
  resolves the orchestrator's `fast` roster entry via `RepoBuilder.Explain.fast_config/1`
  and dispatches a one-shot, non-persisted ephemeral runner (mirroring
  `RepoBuilder.Explain.explain/2`), returning `{:ok, {:async, request_id}}`; the caller
  later receives `{:smart_import_result, request_id, result}`.

  The Fast agent is constrained to reply with a strict JSON envelope, parsed by
  `parse_agent_reply/1`. The runner is injected behind a `:runner` config seam (mirroring
  `RepoBuilder.Workflows.TitleHumanizer`) so tests never hit a model. The agent is told to
  carry the secret NAME only — never a token (BUILD_PROMPT §6).
  """
  alias RepoBuilder.Explain
  alias RepoBuilder.ExternalApis.{ExternalApi, ImportResult, McpImport}
  alias RepoBuilder.ExternalApis.SmartImport.{Request, Server}
  alias RepoBuilder.Orchestrator.Orchestrator

  @default_runner {Server, :start, 1}

  @typedoc "A synchronous deterministic result, or an async-dispatch correlation id."
  @type import_outcome ::
          {:ok, ImportResult.t()}
          | {:ok, {:async, String.t()}}
          | {:error, :no_fast_agent | :empty | :no_orchestrator | term()}

  @doc """
  Smart-import the pasted `blob` for `orchestrator`.

  Returns `{:ok, ImportResult.t()}` for a deterministically recognized config (no model
  hit), `{:ok, {:async, request_id}}` when the Fast agent was dispatched (await
  `{:smart_import_result, request_id, _}`), or `{:error, reason}`.
  """
  @spec import(Orchestrator.t() | nil, String.t()) :: import_outcome()
  def import(orchestrator, blob) when is_binary(blob) do
    case McpImport.parse(blob) do
      {:ok, %ImportResult{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:needs_agent, _hint} -> dispatch_agent(orchestrator, blob)
    end
  end

  @doc """
  Parse the Fast agent's strict-JSON reply into an `ImportResult` (`source: :agent`).

  Tolerates a Markdown fence around the JSON. Returns `{:error, :bad_agent_reply}` for a
  missing/malformed envelope or an out-of-vocabulary `action`/`transport`/`auth_scheme`.
  """
  @spec parse_agent_reply(String.t()) :: {:ok, ImportResult.t()} | {:error, :bad_agent_reply}
  def parse_agent_reply(reply) when is_binary(reply) do
    with {:ok, json} <- decode_envelope(reply),
         {:ok, action} <- fetch_action(json) do
      {:ok, build_result(action, json)}
    else
      _error -> {:error, :bad_agent_reply}
    end
  end

  def parse_agent_reply(_reply), do: {:error, :bad_agent_reply}

  @doc """
  Build the strict-JSON instruction prompt the Fast agent must answer.

  The model interprets `blob` (an MCP config or a description) into a registration draft
  or a single clarifying question, using ONLY the closed transport/auth vocabularies and
  carrying the secret NAME, never a token.
  """
  @spec build_prompt(String.t()) :: String.t()
  def build_prompt(blob) do
    """
    You are registering an external MCP server / API for a developer tool. Read the input
    below (it may be an MCP config JSON, an `mcpServers` snippet, or a free-form
    description) and reply with ONLY a single JSON object — no prose, no Markdown fences.

    Shape:
    {"action":"register"|"question",
     "question":"<one short question, only when action is question>",
     "api":{"name":"<lowercase-key>","transport":#{inspect(ExternalApi.transports())},
            "url":"<http/sse only>","command":"<stdio only>","args":["..."],
            "auth_scheme":#{inspect(ExternalApi.auth_schemes())},
            "auth_header":"<custom header name, for the header scheme>",
            "secret_name":"<ENV_VAR_NAME, the vault reference — NEVER a token value>",
            "provider":"<optional>","description":"<optional>"}}

    Rules:
    - `name` is lowercase letters/digits/_/- starting with a letter.
    - http and sse need a `url`; stdio needs a `command`.
    - If the server needs auth, set `auth_scheme` to "bearer" or "header" and put the
      vault env-var NAME in `secret_name` (e.g. PIXELLAB_API_KEY). NEVER put a real token
      anywhere in the JSON.
    - Use action "question" (with one short `question`) when a required field is unknowable.

    Input:
    #{blob}
    """
  end

  # --- agent dispatch ---

  @spec dispatch_agent(Orchestrator.t() | nil, String.t()) :: import_outcome()
  defp dispatch_agent(nil, _blob), do: {:error, :no_orchestrator}

  defp dispatch_agent(%Orchestrator{} = orchestrator, blob) do
    with {:ok, config} <- Explain.fast_config(orchestrator) do
      request = %Request{
        request_id: generate_request_id(),
        prompt: build_prompt(blob),
        harness: config.harness,
        provider: config.provider,
        model: config.model,
        reply_to: self()
      }

      case invoke_runner(request) do
        {:ok, _pid} -> {:ok, {:async, request.request_id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec invoke_runner(Request.t()) :: DynamicSupervisor.on_start_child()
  defp invoke_runner(request) do
    {mod, fun, _arity} =
      Application.get_env(:repo_builder, __MODULE__, [])[:runner] || @default_runner

    apply(mod, fun, [request])
  end

  # --- reply parsing ---

  @spec decode_envelope(String.t()) :: {:ok, map()} | :error
  defp decode_envelope(reply) do
    case Jason.decode(strip_fences(reply)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> :error
    end
  end

  @spec strip_fences(String.t()) :: String.t()
  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  @spec fetch_action(map()) :: {:ok, ImportResult.action()} | :error
  defp fetch_action(%{"action" => "register"}), do: {:ok, :register}
  defp fetch_action(%{"action" => "question"}), do: {:ok, :question}
  defp fetch_action(_json), do: :error

  @spec build_result(ImportResult.action(), map()) :: ImportResult.t()
  defp build_result(action, json) do
    api = if is_map(json["api"]), do: json["api"], else: %{}

    params =
      %{
        "name" => string_or_nil(api["name"]),
        "transport" => enum_or_nil(api["transport"], ExternalApi.transports()),
        "url" => string_or_nil(api["url"]),
        "command" => string_or_nil(api["command"]),
        "args" => string_list(api["args"]),
        "auth_scheme" => enum_or_nil(api["auth_scheme"], ExternalApi.auth_schemes()),
        "auth_header" => string_or_nil(api["auth_header"]),
        "secret_name" => string_or_nil(api["secret_name"]),
        "provider" => string_or_nil(api["provider"]),
        "description" => string_or_nil(api["description"])
      }
      |> drop_nil_values()

    %ImportResult{
      action: action,
      api_params: params,
      secret_name: params["secret_name"],
      secret_value: nil,
      question: string_or_nil(json["question"]),
      source: :agent
    }
  end

  # --- coercion ---

  defp enum_or_nil(value, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in Enum.map(allowed, &Atom.to_string/1), do: normalized, else: nil
  end

  defp enum_or_nil(_value, _allowed), do: nil

  @spec string_or_nil(term()) :: String.t() | nil
  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil

  @spec string_list(term()) :: [String.t()]
  defp string_list(list) when is_list(list),
    do: list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

  defp string_list(_other), do: []

  defp drop_nil_values(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)

  @spec generate_request_id() :: String.t()
  defp generate_request_id do
    8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
