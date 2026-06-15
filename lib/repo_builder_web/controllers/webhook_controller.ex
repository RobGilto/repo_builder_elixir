defmodule RepoBuilderWeb.WebhookController do
  @moduledoc """
  Verifies a signed webhook (HMAC + timestamp replay window) via
  `RepoBuilder.Webhooks` and, only on success, durably triggers a workflow
  (BUILD_PROMPT.md §7). An invalid/unsigned/expired/unknown request is rejected with
  4xx and never enqueues a job.
  """
  use RepoBuilderWeb, :controller

  alias RepoBuilder.Webhooks

  @spec trigger(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def trigger(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = get_req_header_value(conn, "x-signature")
    timestamp = get_req_header_value(conn, "x-timestamp")

    case Webhooks.verify_and_trigger(raw_body, signature, timestamp) do
      {:ok, run_id} ->
        conn |> put_status(:accepted) |> json(%{status: "accepted", run_id: run_id})

      {:error, reason} ->
        conn
        |> put_status(status_for(reason))
        |> json(%{status: "rejected", error: to_string(reason)})
    end
  end

  @spec get_req_header_value(Plug.Conn.t(), String.t()) :: String.t() | nil
  defp get_req_header_value(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp status_for(:workflow_not_found), do: :not_found
  defp status_for(:invalid_payload), do: :unprocessable_entity
  defp status_for(:missing_secret), do: :service_unavailable
  defp status_for(_reason), do: :unauthorized
end
