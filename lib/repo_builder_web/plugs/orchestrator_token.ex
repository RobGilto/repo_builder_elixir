defmodule RepoBuilderWeb.Plugs.OrchestratorToken do
  @moduledoc """
  Per-orchestrator bearer-token auth for the MCP-over-HTTP tool surface (issue-c).

  Reads the `:orchestrator_id` path param and the `Authorization: Bearer <token>`
  header, verifies the token via `RepoBuilder.Orchestrators.verify_token/2`
  (constant-time hash compare), and on success assigns `:orchestrator_id`. Any
  missing/malformed/wrong/expired token → `401` with a JSON-RPC error body and
  `halt` (the tool is NEVER executed). Tokens are never logged.
  """
  import Plug.Conn

  alias RepoBuilder.Orchestrators

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with id when is_binary(id) <- conn.params["orchestrator_id"],
         {:ok, token} <- bearer_token(conn),
         {:ok, orchestrator} <- Orchestrators.verify_token(id, token) do
      assign(conn, :orchestrator_id, orchestrator.id)
    else
      _ -> unauthorized(conn)
    end
  end

  @spec bearer_token(Plug.Conn.t()) :: {:ok, String.t()} | :error
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  defp unauthorized(conn) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32_000, "message" => "unauthorized"}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
