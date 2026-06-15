defmodule RepoBuilderWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Plug.Parsers body reader that caches the RAW request body for webhook HMAC
  verification (BUILD_PROMPT.md §7). Parsers consume the body, so the exact signed
  bytes must be captured here before parsing. Scoped to `/webhooks` paths to avoid
  retaining bodies for every request.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if String.starts_with?(conn.request_path, "/webhooks") do
        Plug.Conn.assign(conn, :raw_body, body)
      else
        conn
      end

    {:ok, body, conn}
  end
end
