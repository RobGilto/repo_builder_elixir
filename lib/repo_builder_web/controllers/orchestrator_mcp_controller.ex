defmodule RepoBuilderWeb.OrchestratorMCPController do
  @moduledoc """
  The orchestrator's tool surface, spoken as MCP over HTTP (JSON-RPC 2.0). This is
  the SINGLE server-side tool endpoint both bindings reach — Claude's native MCP
  (via a generated `.mcp.json`) and the pi extension (via `fetch`) — so tool
  behavior is identical regardless of harness.

  Implements exactly the three methods the bindings need —
  `initialize` / `tools/list` / `tools/call` — plus the `notifications/initialized`
  no-op. Tool definitions come from `RepoBuilder.Orchestrator.ToolCatalog`; calls
  dispatch to `RepoBuilder.Orchestrator.Tools` and are wrapped in the MCP
  `{content: [...], isError: bool}` shape. A `{:error, reason}` from a tool is a
  successful JSON-RPC response with `isError: true` (NOT a protocol error); only
  malformed requests / unknown methods produce a JSON-RPC error object. It NEVER
  500s on bad input.

  The endpoint is internal and per-orchestrator-token scoped
  (`RepoBuilderWeb.Plugs.OrchestratorToken`); bind it to localhost.
  """
  use RepoBuilderWeb, :controller

  alias RepoBuilder.Orchestrator.{ToolCatalog, Tools}

  @protocol_version "2024-11-05"

  @spec rpc(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc(conn, params) do
    orchestrator_id = conn.assigns.orchestrator_id

    case handle(params, orchestrator_id) do
      :noreply -> send_resp(conn, 204, "")
      response -> json(conn, response)
    end
  end

  # --- JSON-RPC method dispatch ---
  # Inference-only specs from here down — the helpers return concrete-shaped
  # JSON-RPC maps that narrow below a hand-written `map()` (dialyzer
  # contract_supertype), so we let dialyzer infer the precise success typing.

  defp handle(%{"method" => "initialize", "id" => id}, _orchestrator_id) do
    ok(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "repo_builder.orchestrator", "version" => "1"}
    })
  end

  defp handle(%{"method" => "notifications/" <> _rest}, _orchestrator_id), do: :noreply

  defp handle(%{"method" => "tools/list", "id" => id}, _orchestrator_id) do
    ok(id, %{"tools" => Enum.map(ToolCatalog.tools(), &tool_descriptor/1)})
  end

  defp handle(%{"method" => "tools/call", "id" => id} = req, orchestrator_id) do
    params = Map.get(req, "params", %{})
    name = params["name"]
    args = normalize_args(params["arguments"])

    if is_binary(name) do
      ok(id, call_result(name, orchestrator_id, args))
    else
      error(id, -32_602, "invalid params: missing tool name")
    end
  end

  defp handle(%{"method" => method, "id" => id}, _orchestrator_id) when is_binary(method) do
    error(id, -32_601, "method not found: #{method}")
  end

  defp handle(%{"id" => id}, _orchestrator_id), do: error(id, -32_600, "invalid request")
  defp handle(_req, _orchestrator_id), do: error(nil, -32_600, "invalid request")

  # --- tool call ⇒ MCP content envelope ---

  defp call_result(name, orchestrator_id, args) do
    case Tools.call(name, orchestrator_id, args) do
      {:ok, result} -> %{"content" => [text_content(result)], "isError" => false}
      {:error, reason} -> %{"content" => [text_content(reason_text(reason))], "isError" => true}
    end
  end

  # Inference-only specs — these helpers return concrete-shaped JSON maps that
  # narrow below a hand-written `map()` (dialyzer contract_supertype otherwise).
  defp text_content(value) when is_binary(value), do: %{"type" => "text", "text" => value}
  defp text_content(value), do: %{"type" => "text", "text" => Jason.encode!(value)}

  # `Orchestrator.Tools` only ever returns an atom or string reason (changesets are
  # stringified at that boundary), so those two clauses fully cover the input.
  @spec reason_text(atom() | String.t()) :: String.t()
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: to_string(reason)

  defp tool_descriptor(%{name: name, description: description, input_schema: schema}) do
    %{"name" => name, "description" => description, "inputSchema" => schema}
  end

  @spec normalize_args(term()) :: map()
  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_args), do: %{}

  # Inference-only spec — the concrete JSON-RPC envelope map narrows below a
  # hand-written `map()`, which dialyzer flags as a contract supertype.
  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
